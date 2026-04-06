//
//  HomeView.swift
//  Sora
//
//  Home browse view with auto-populated content rows from loaded modules.
//

import SwiftUI
import NukeUI
import JavaScriptCore

// MARK: - Home Data Manager

@MainActor
class HomeDataManager: ObservableObject {
    static let shared = HomeDataManager()
    
    @Published var sections: [HomeSection] = []
    @Published var isLoading = false
    @Published var hasLoaded = false
    
    struct HomeSection: Identifiable {
        let id = UUID()
        let title: String
        let items: [HomeItem]
        let module: ScrapingModule
    }
    
    struct HomeItem: Identifiable {
        let id = UUID()
        let title: String
        let imageUrl: String
        let href: String
    }
    
    private let categoryQueries: [(String, String, [String])] = [
        ("Trending Movies", "avengers", ["movie", "show"]),
        ("Popular TV Shows", "game of thrones", ["show", "movie"]),
        ("New Releases", "dune", ["movie", "show"]),
        ("Top Anime", "naruto", ["anime"]),
        ("Action", "john wick", ["movie", "show"]),
        ("Comedy", "hangover", ["movie", "show"]),
        ("Horror", "conjuring", ["movie", "show"]),
        ("Sci-Fi", "star wars", ["movie", "show"]),
        ("Romance Anime", "love", ["anime"]),
        ("K-Drama", "love", ["drama", "show"]),
    ]
    
    func loadContent(modules: [ScrapingModule], moduleManager: ModuleManager) async {
        guard !isLoading, !modules.isEmpty else { return }
        isLoading = true
        
        var newSections: [HomeSection] = []
        var usedModuleIndices: [String: Int] = [:]
        
        for (title, query, typeKeywords) in categoryQueries {
            if Task.isCancelled { break }
            
            let typeKey = typeKeywords.joined(separator: ",")
            let nextIndex = usedModuleIndices[typeKey] ?? 0
            guard let module = findBestModule(modules: modules, typeKeywords: typeKeywords, offset: nextIndex) else { continue }
            usedModuleIndices[typeKey] = nextIndex + 1
            
            do {
                let jsContent = try moduleManager.getModuleContent(module)
                
                // Use local JSContext to avoid race conditions with SearchView's JSController.shared
                let items: [HomeItem] = await withCheckedContinuation { continuation in
                    var hasResumed = false
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        if !hasResumed {
                            hasResumed = true
                            continuation.resume(returning: [])
                        }
                    }
                    
                    if module.metadata.asyncJS == true {
                        // Async modules: JS handles HTTP requests via fetchv2
                        let localContext = JSContext()!
                        localContext.setupJavaScriptEnvironment()
                        localContext.evaluateScript(jsContent)
                        
                        guard let searchFn = localContext.objectForKeyedSubscript("searchResults"),
                              let promise = searchFn.call(withArguments: [query]) else {
                            if !hasResumed { hasResumed = true; continuation.resume(returning: []) }
                            return
                        }
                        
                        let thenBlock: @convention(block) (JSValue) -> Void = { result in
                            guard !hasResumed else { return }
                            if let jsonStr = result.toString(),
                               let data = jsonStr.data(using: .utf8),
                               let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                                let homeItems = array.prefix(20).compactMap { dict -> HomeItem? in
                                    guard let t = dict["title"] as? String,
                                          let img = dict["image"] as? String,
                                          let href = dict["href"] as? String else { return nil }
                                    return HomeItem(title: t, imageUrl: img, href: href)
                                }
                                hasResumed = true
                                DispatchQueue.main.async { continuation.resume(returning: Array(homeItems)) }
                            } else {
                                hasResumed = true
                                DispatchQueue.main.async { continuation.resume(returning: []) }
                            }
                        }
                        
                        let catchBlock: @convention(block) (JSValue) -> Void = { _ in
                            guard !hasResumed else { return }
                            hasResumed = true
                            DispatchQueue.main.async { continuation.resume(returning: []) }
                        }
                        
                        let thenFn = JSValue(object: thenBlock, in: localContext)
                        let catchFn = JSValue(object: catchBlock, in: localContext)
                        promise.invokeMethod("then", withArguments: [thenFn as Any])
                        promise.invokeMethod("catch", withArguments: [catchFn as Any])
                        
                    } else {
                        // Non-async modules: fetch HTML, then parse with local JSContext
                        let searchUrl = module.metadata.searchBaseUrl.replacingOccurrences(
                            of: "%s",
                            with: query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        )
                        
                        guard let url = URL(string: searchUrl) else {
                            if !hasResumed { hasResumed = true; continuation.resume(returning: []) }
                            return
                        }
                        
                        URLSession.custom.dataTask(with: url) { data, _, error in
                            guard !hasResumed else { return }
                            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                                hasResumed = true
                                DispatchQueue.main.async { continuation.resume(returning: []) }
                                return
                            }
                            
                            let localContext = JSContext()!
                            localContext.setupJavaScriptEnvironment()
                            localContext.evaluateScript(jsContent)
                            
                            if let parseFn = localContext.objectForKeyedSubscript("searchResults"),
                               let results = parseFn.call(withArguments: [html]).toArray() as? [[String: String]] {
                                let homeItems = results.prefix(20).map {
                                    HomeItem(title: $0["title"] ?? "", imageUrl: $0["image"] ?? "", href: $0["href"] ?? "")
                                }
                                hasResumed = true
                                DispatchQueue.main.async { continuation.resume(returning: Array(homeItems)) }
                            } else {
                                hasResumed = true
                                DispatchQueue.main.async { continuation.resume(returning: []) }
                            }
                        }.resume()
                    }
                }
                
                if !items.isEmpty {
                    newSections.append(HomeSection(title: title, items: items, module: module))
                }
            } catch {
                Logger.shared.log("HomeView: Failed to load \(title) from \(module.metadata.sourceName): \(error.localizedDescription)", type: "Error")
            }
        }
        
        sections = newSections
        isLoading = false
        hasLoaded = true
    }
    
    private func findBestModule(modules: [ScrapingModule], typeKeywords: [String], offset: Int = 0) -> ScrapingModule? {
        let nameMatches = modules.filter { module in
            let name = module.metadata.sourceName.lowercased()
            let lang = (module.metadata.language ?? "").lowercased()
            let moduleType = (module.metadata.type ?? "").lowercased()
            let isEnglish = lang.contains("english") || lang.contains("multi") || lang.isEmpty
            guard isEnglish else { return false }
            
            if typeKeywords.contains("anime") {
                return name.contains("anime") || name.contains("aniwave") || name.contains("hianime") || name.contains("pahe") || moduleType.contains("anime")
            } else if typeKeywords.contains("drama") {
                return name.contains("drama") || name.contains("kisskh") || moduleType.contains("drama")
            } else {
                let isAnime = name.contains("anime") || name.contains("aniwave") || name.contains("hianime") || name.contains("pahe") || moduleType.contains("anime")
                let isDrama = name.contains("drama") || name.contains("kisskh") || moduleType.contains("drama")
                let isCartoon = name.contains("cartoon")
                let isIPTV = name.contains("iptv")
                return !isAnime && !isDrama && !isCartoon && !isIPTV
            }
        }
        
        if !nameMatches.isEmpty {
            let idx = offset % nameMatches.count
            return nameMatches[idx]
        }
        
        // Fallback: any non-anime, non-drama module
        let fallback = modules.filter { module in
            let name = module.metadata.sourceName.lowercased()
            return !name.contains("iptv")
        }
        return fallback.first ?? modules.first
    }
}

// MARK: - Home View

struct HomeView: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @EnvironmentObject private var libraryManager: LibraryManager
    @StateObject private var homeData = HomeDataManager.shared
    @State private var continueWatchingItems: [ContinueWatchingItem] = []
    @State private var isActive: Bool = false
    @State private var loadingTask: Task<Void, Never>?
    
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Home")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                    
                    // Continue Watching - reuse Sora's existing component
                    if !continueWatchingItems.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                HStack(spacing: 4) {
                                    Image(systemName: "play.fill")
                                        .font(.subheadline)
                                    Text("Continue Watching")
                                        .font(.title3)
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 10)
                            
                            ContinueWatchingSection(
                                items: $continueWatchingItems,
                                markAsWatched: { item in
                                    ContinueWatchingManager.shared.remove(item: item)
                                    continueWatchingItems.removeAll { $0.id == item.id }
                                },
                                removeItem: { item in
                                    ContinueWatchingManager.shared.remove(item: item)
                                    continueWatchingItems.removeAll { $0.id == item.id }
                                }
                            )
                        }
                    }
                    
                    // Loading skeleton
                    if homeData.isLoading && homeData.sections.isEmpty {
                        HomeSkeletonView()
                    }
                    
                    // Browse content rows
                    ForEach(homeData.sections) { section in
                        HomeSectionRow(
                            section: section,
                            moduleManager: moduleManager,
                            libraryManager: libraryManager
                        )
                    }
                    
                    // Empty state
                    if homeData.hasLoaded && homeData.sections.isEmpty && !homeData.isLoading {
                        HomeEmptyState()
                    }
                    
                    Spacer().frame(height: 100)
                }
            }
            .scrollViewBottomPadding()
            .onAppear {
                isActive = true
                loadContinueWatching()
                triggerLoadIfReady()
                NotificationCenter.default.post(name: .showTabBar, object: nil)
            }
            .onDisappear {
                isActive = false
                loadingTask?.cancel()
            }
            .onChange(of: moduleManager.modules.count) { newCount in
                if newCount > 0 && !homeData.hasLoaded {
                    loadingTask = Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        await homeData.loadContent(modules: moduleManager.modules, moduleManager: moduleManager)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ContinueWatchingDidUpdate)) { _ in
                loadContinueWatching()
            }
            .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
                let isMediaInfoActive = UserDefaults.standard.bool(forKey: "isMediaInfoActive")
                let isReaderActive = UserDefaults.standard.bool(forKey: "isReaderActive")
                if isActive && !isMediaInfoActive && !isReaderActive {
                    NotificationCenter.default.post(name: .showTabBar, object: nil)
                }
            }
            .refreshable {
                homeData.hasLoaded = false
                await homeData.loadContent(modules: moduleManager.modules, moduleManager: moduleManager)
                loadContinueWatching()
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
    }
    
    private func loadContinueWatching() {
        continueWatchingItems = ContinueWatchingManager.shared.fetchItems()
    }
    
    private func triggerLoadIfReady() {
        if !homeData.hasLoaded && !moduleManager.modules.isEmpty {
            loadingTask = Task {
                await homeData.loadContent(modules: moduleManager.modules, moduleManager: moduleManager)
            }
        } else if moduleManager.modules.isEmpty {
            loadingTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !homeData.hasLoaded && !moduleManager.modules.isEmpty {
                    await homeData.loadContent(modules: moduleManager.modules, moduleManager: moduleManager)
                }
            }
        }
    }
}

// MARK: - Section Row

struct HomeSectionRow: View {
    let section: HomeDataManager.HomeSection
    let moduleManager: ModuleManager
    let libraryManager: LibraryManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(section.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Text(section.module.metadata.sourceName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(section.items) { item in
                        NavigationLink(destination:
                            MediaInfoView(
                                title: item.title,
                                imageUrl: item.imageUrl,
                                href: item.href,
                                module: section.module
                            )
                            .environmentObject(moduleManager)
                            .environmentObject(libraryManager)
                        ) {
                            HomePosterCard(item: item)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

struct HomePosterCard: View {
    let item: HomeDataManager.HomeItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyImage(url: URL(string: item.imageUrl)) { state in
                if let uiImage = state.imageContainer?.image {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.tertiary)
                        .overlay(
                            ProgressView()
                                .tint(.secondary)
                        )
                }
            }
            .frame(width: 130, height: 195)
            .cornerRadius(10)
            .clipped()
            
            Text(item.title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(2)
                .frame(width: 130, alignment: .leading)
        }
    }
}

// MARK: - Skeleton Loading

struct HomeSkeletonView: View {
    var body: some View {
        ForEach(0..<4, id: \.self) { _ in
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.tertiary)
                    .frame(width: 150, height: 20)
                    .padding(.horizontal, 20)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<5, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(.tertiary)
                                    .frame(width: 130, height: 195)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.tertiary)
                                    .frame(width: 100, height: 12)
                            }
                            .shimmering()
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Empty State

struct HomeEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            
            Text("No Content Available")
                .font(.title3)
                .fontWeight(.semibold)
            
            Text("Add modules in Settings to start browsing movies, TV shows, and anime.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
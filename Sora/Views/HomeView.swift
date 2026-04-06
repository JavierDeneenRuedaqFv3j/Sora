//
//  HomeView.swift
//  Sora
//
//  Home browse view with auto-populated content rows from loaded modules.
//

import SwiftUI
import NukeUI

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
    
    // TMDB keyword categories (require VidEasy/VidFast/VidLink — they support !-prefixed keywords)
    private let tmdbCategories: [(String, String)] = [
        ("Trending", "!trending"),
        ("Popular Movies", "!popular-movie"),
        ("Popular TV Shows", "!popular-tv"),
        ("Top Rated Movies", "!top-rated-movie"),
        ("Top Rated TV", "!top-rated-tv"),
    ]
    
    // Search-based categories using regular queries
    private let searchCategories: [(String, String, [String])] = [
        ("Top Anime", "naruto", ["anime"]),
        ("Action Movies", "john wick", ["movie", "show"]),
        ("Sci-Fi", "star wars", ["movie", "show"]),
        ("Horror", "conjuring", ["movie", "show"]),
        ("Comedy", "hangover", ["movie", "show"]),
        ("Romance", "notebook", ["movie", "show"]),
        ("Popular Anime", "one piece", ["movie", "show", "anime"]),
        ("Turkish Series", "ask", ["turkish"]),
        ("K-Drama", "love", ["drama"]),
        ("Cartoons", "batman", ["cartoon"]),
    ]
    
    // Live TV categories (IPTV-org module — searches channel names)
    private let liveTVCategories: [(String, String)] = [
        ("🔴 Turkish TV", "trt"),
        ("🔴 Netherlands TV", "nederland"),
        ("🔴 beIN Sports", "bein"),
    ]
    
    // Module names that support TMDB !-keyword browsing
    private let tmdbModuleNames: Set<String> = ["videasy", "vidfast", "vidlink"]
    
    func loadContent(modules: [ScrapingModule], moduleManager: ModuleManager) async {
        guard !isLoading, !modules.isEmpty else { return }
        isLoading = true
        
        let jsController = JSController.shared
        var newSections: [HomeSection] = []
        
        // --- Phase 1: TMDB categories (VidEasy/VidFast/VidLink only) ---
        let tmdbModules = modules.filter { tmdbModuleNames.contains($0.metadata.sourceName.lowercased()) }
        
        for (idx, (title, query)) in tmdbCategories.enumerated() {
            if Task.isCancelled { break }
            guard !tmdbModules.isEmpty else { break }
            
            let module = tmdbModules[idx % tmdbModules.count]
            if let section = await fetchSection(title: title, query: query, module: module, moduleManager: moduleManager, jsController: jsController) {
                newSections.append(section)
            }
        }
        
        // --- Phase 2: Search-based categories ---
        for (title, query, typeKeywords) in searchCategories {
            if Task.isCancelled { break }
            
            guard let module = findBestModule(modules: modules, typeKeywords: typeKeywords) else { continue }
            if let section = await fetchSection(title: title, query: query, module: module, moduleManager: moduleManager, jsController: jsController) {
                newSections.append(section)
            }
        }
        
        // --- Phase 3: Live TV categories (IPTV-org) ---
        if let iptvModule = modules.first(where: { $0.metadata.sourceName.lowercased().contains("iptv") }) {
            for (title, query) in liveTVCategories {
                if Task.isCancelled { break }
                if let section = await fetchSection(title: title, query: query, module: iptvModule, moduleManager: moduleManager, jsController: jsController) {
                    newSections.append(section)
                }
            }
        }
        
        sections = newSections
        isLoading = false
        hasLoaded = true
    }
    
    private func fetchSection(title: String, query: String, module: ScrapingModule, moduleManager: ModuleManager, jsController: JSController) async -> HomeSection? {
        do {
            let jsContent = try moduleManager.getModuleContent(module)
            jsController.loadScript(jsContent)
            
            let items: [HomeItem] = await withCheckedContinuation { continuation in
                var hasResumed = false
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(returning: [])
                    }
                }
                
                let handler: ([SearchItem]) -> Void = { searchItems in
                    guard !hasResumed else { return }
                    hasResumed = true
                    let homeItems = searchItems
                        .filter { $0.title != "Error" && !$0.title.isEmpty && !$0.title.hasPrefix("Search failed") }
                        .prefix(20)
                        .map { item in HomeItem(title: item.title, imageUrl: item.imageUrl, href: item.href) }
                    continuation.resume(returning: Array(homeItems))
                }
                
                if module.metadata.asyncJS == true {
                    jsController.fetchJsSearchResults(keyword: query, module: module, completion: handler)
                } else {
                    jsController.fetchSearchResults(keyword: query, module: module, completion: handler)
                }
            }
            
            if !items.isEmpty {
                return HomeSection(title: title, items: items, module: module)
            }
        } catch {
            Logger.shared.log("HomeView: Failed to load \(title) from \(module.metadata.sourceName): \(error.localizedDescription)", type: "Error")
        }
        return nil
    }
    
    private func findBestModule(modules: [ScrapingModule], typeKeywords: [String]) -> ScrapingModule? {
        let preferredAnime = ["hianime", "animekai", "animeheaven", "anicrush", "fireanime", "animenosub", "kimcartoon"]
        let preferredMovieTV = ["videasy", "vidfast", "vidlink", "1movies", "ashi", "himovies", "hexa"]
        let preferredTurkish = ["turkish123"]
        let preferredDrama = ["kisskh", "kissasian"]
        
        let candidates = modules.filter { module in
            let name = module.metadata.sourceName.lowercased()
            let lang = (module.metadata.language ?? "").lowercased()
            let moduleType = (module.metadata.type ?? "").lowercased()
            let isEnglish = lang.contains("english") || lang.contains("multi") || lang.isEmpty
            
            if typeKeywords.contains("turkish") {
                return lang.contains("turkish") || name.contains("turkish")
            } else if typeKeywords.contains("anime") {
                guard isEnglish else { return false }
                return name.contains("anime") || name.contains("hianime") || name.contains("cartoon") || moduleType.contains("anime")
            } else if typeKeywords.contains("cartoon") {
                guard isEnglish else { return false }
                return name.contains("cartoon") || name.contains("toon")
            } else if typeKeywords.contains("drama") {
                return name.contains("kisskh") || name.contains("kissasian") || name.contains("drama") || moduleType.contains("drama")
            } else {
                guard isEnglish else { return false }
                let isAnimeOnly = (name.contains("anime") || name.contains("hianime")) && !moduleType.contains("movie") && !moduleType.contains("show")
                let isIPTV = name.contains("iptv")
                let isTurkish = lang.contains("turkish")
                return !isAnimeOnly && !isIPTV && !isTurkish
            }
        }
        
        let preferred: [String]
        if typeKeywords.contains("turkish") { preferred = preferredTurkish }
        else if typeKeywords.contains("anime") || typeKeywords.contains("cartoon") { preferred = preferredAnime }
        else if typeKeywords.contains("drama") { preferred = preferredDrama }
        else { preferred = preferredMovieTV }
        
        let sorted = candidates.sorted { a, b in
            let aIdx = preferred.firstIndex(where: { a.metadata.sourceName.lowercased().contains($0) }) ?? 999
            let bIdx = preferred.firstIndex(where: { b.metadata.sourceName.lowercased().contains($0) }) ?? 999
            return aIdx < bIdx
        }
        
        return sorted.first ?? candidates.first ?? modules.first
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
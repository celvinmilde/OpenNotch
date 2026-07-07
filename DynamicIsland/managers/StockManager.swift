/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import Combine
import Defaults

/// Fetches a single stock/ETF quote for the notch widget. Uses Yahoo
/// Finance's public chart endpoint — no API key needed, same "free public
/// API" approach as the weather feature (OpenMeteo).
@MainActor
final class StockManager: ObservableObject {
    static let shared = StockManager()

    @Published private(set) var symbol: String = ""
    @Published private(set) var companyName: String?
    @Published private(set) var price: Double?
    @Published private(set) var changePercent: Double?
    @Published private(set) var currencySymbol: String = "$"
    @Published private(set) var history: [StockPricePoint] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastErrorMessage: String?

    /// Whether the price is up (green) or down (red) versus the start of
    /// the shown history — falls back to the daily change if there's no
    /// history yet.
    var isPositive: Bool {
        if let first = history.first?.price, let last = history.last?.price {
            return last >= first
        }
        return (changePercent ?? 0) >= 0
    }

    private var refreshTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private let refreshInterval: Duration = .seconds(60)

    private init() {
        symbol = Defaults[.stockSymbol]
        observeSettings()
    }

    private func observeSettings() {
        Defaults.publisher(.enableStocksFeature)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                if change.newValue {
                    self?.startRefreshing()
                } else {
                    self?.stopRefreshing()
                }
            }
            .store(in: &cancellables)

        Defaults.publisher(.stockSymbol)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.symbol = change.newValue
                guard Defaults[.enableStocksFeature] else { return }
                Task { await self?.refreshNow() }
            }
            .store(in: &cancellables)

        if Defaults[.enableStocksFeature] {
            startRefreshing()
        }
    }

    func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                try? await Task.sleep(for: self?.refreshInterval ?? .seconds(60))
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refreshNow() async {
        guard let quote = await Self.fetchQuote(symbol: Defaults[.stockSymbol]) else {
            lastErrorMessage = "Kein Kurs gefunden"
            return
        }
        companyName = quote.name
        price = quote.price
        changePercent = quote.changePercent
        currencySymbol = quote.currencySymbol
        history = quote.history
        lastErrorMessage = nil
    }

    /// Looks up a ticker without touching the persisted state — used by the
    /// settings UI to preview/validate a symbol before saving it.
    static func lookup(symbol: String) async -> StockQuote? {
        await fetchQuote(symbol: symbol)
    }

    /// Resolves free-text input — a ticker, a company/ETF name, or an ISIN
    /// (e.g. "IE00B4L5Y983") — to one or more matching symbols. Yahoo's
    /// search endpoint accepts all three, unlike the chart endpoint which
    /// only accepts an exact ticker.
    static func search(query: String) async -> [StockSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/search?q=\(encoded)&quotesCount=6&newsCount=0")
        else { return [] }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(YahooSearchResponse.self, from: data)
        else { return [] }

        return (decoded.quotes ?? []).compactMap { quote in
            guard let symbol = quote.symbol else { return nil }
            let name = quote.shortname ?? quote.longname ?? symbol
            return StockSearchResult(symbol: symbol, name: name, exchange: quote.exchange ?? "")
        }
    }

    private static func fetchQuote(symbol: String) async -> StockQuote? {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=1mo&interval=1d")
        else { return nil }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(YahooChartResponse.self, from: data),
              let result = decoded.chart.result?.first,
              let price = result.meta.regularMarketPrice
        else { return nil }

        let meta = result.meta
        let previousClose = meta.chartPreviousClose ?? meta.previousClose
        let changePercent: Double? = {
            guard let previousClose, previousClose != 0 else { return nil }
            return (price - previousClose) / previousClose * 100
        }()

        var history: [StockPricePoint] = []
        if let timestamps = result.timestamp,
           let closes = result.indicators?.quote?.first?.close {
            for (index, timestamp) in timestamps.enumerated() where index < closes.count {
                guard let close = closes[index] else { continue }
                history.append(StockPricePoint(date: Date(timeIntervalSince1970: TimeInterval(timestamp)), price: close))
            }
        }

        return StockQuote(
            symbol: meta.symbol ?? trimmed,
            name: meta.shortName ?? meta.symbol ?? trimmed,
            price: price,
            changePercent: changePercent,
            currencySymbol: currencySymbol(for: meta.currency ?? "USD"),
            history: history
        )
    }

    private static func currencySymbol(for code: String) -> String {
        switch code.uppercased() {
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "JPY": return "¥"
        default: return code
        }
    }
}

struct StockQuote {
    let symbol: String
    let name: String
    let price: Double
    let changePercent: Double?
    let currencySymbol: String
    var history: [StockPricePoint] = []
}

struct StockPricePoint: Identifiable {
    let date: Date
    let price: Double
    var id: Date { date }
}

struct StockSearchResult: Identifiable {
    let symbol: String
    let name: String
    let exchange: String
    var id: String { symbol }
}

private struct YahooSearchResponse: Decodable {
    let quotes: [Quote]?

    struct Quote: Decodable {
        let symbol: String?
        let shortname: String?
        let longname: String?
        let exchange: String?
    }
}

private struct YahooChartResponse: Decodable {
    let chart: Chart

    struct Chart: Decodable {
        let result: [Result]?
    }

    struct Result: Decodable {
        let meta: Meta
        let timestamp: [Int]?
        let indicators: Indicators?
    }

    struct Indicators: Decodable {
        let quote: [Quote]?
    }

    struct Quote: Decodable {
        let close: [Double?]?
    }

    struct Meta: Decodable {
        let symbol: String?
        let shortName: String?
        let regularMarketPrice: Double?
        let previousClose: Double?
        let chartPreviousClose: Double?
        let currency: String?
    }
}

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

import SwiftUI
import Charts
import Defaults

/// Full notch page for the Stocks feature — opened via its own tab, same
/// pattern as Stats/Timer. Shows a price history graph (green when up over
/// the shown period, red when down), the current price, and the day's
/// percent change.
struct NotchStocksView: View {
    @ObservedObject private var stockManager = StockManager.shared
    @Default(.enableStocksFeature) private var enableStocksFeature

    private var trendColor: Color {
        stockManager.isPositive ? .green : .red
    }

    private var changeText: String {
        guard let change = stockManager.changePercent else { return "" }
        let sign = change >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", change))%"
    }

    /// A tight range around the actual price movement — `.automatic` alone
    /// tends to include enough headroom that small real moves look almost
    /// flat, so this pads only ~8% beyond the min/max instead.
    private var chartYDomain: ClosedRange<Double> {
        let prices = stockManager.history.map(\.price)
        guard let minPrice = prices.min(), let maxPrice = prices.max(), minPrice < maxPrice else {
            let price = stockManager.price ?? 1
            return (price * 0.95)...(price * 1.05)
        }
        let span = maxPrice - minPrice
        let padding = span * 0.12
        return (minPrice - padding)...(maxPrice + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if stockManager.history.count > 1 {
                chart
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
                Text(stockManager.lastErrorMessage ?? "Lade Kursdaten…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await stockManager.refreshNow()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stockManager.companyName ?? stockManager.symbol)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(stockManager.symbol)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let price = stockManager.price {
                    Text("\(stockManager.currencySymbol)\(String(format: "%.2f", price))")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }

                if stockManager.changePercent != nil {
                    Text(changeText)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(trendColor)
                }
            }
        }
    }

    private var chart: some View {
        Chart(stockManager.history) { point in
            AreaMark(
                x: .value("Zeit", point.date),
                y: .value("Preis", point.price)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [trendColor.opacity(0.35), trendColor.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Zeit", point.date),
                y: .value("Preis", point.price)
            )
            .foregroundStyle(trendColor)
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine()
                AxisValueLabel()
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .chartYScale(domain: chartYDomain)
    }
}

//
//  SessionDetailView.swift
//  iSurf-Watch
//
//  Detailed view of a completed session
//

import SwiftUI

struct SessionDetailView: View {
    let session: Session
    @AppStorage("appLanguage") private var languageCode: String = "en"
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading) {
                    Text(session.sport.displayName)
                        .font(.headline)
                    
                    Text(formatDate(session.startTime))
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
                Divider()
                
                // Summary stats
                VStack(spacing: 12) {
                    StatRow(label: L("detail.duration"), value: formatDuration(session.duration))
                    StatRow(label: L("detail.total_distance"), value: formatDistance(session.distance))
                    StatRow(label: L("detail.max_speed"), value: formatSpeed(session.maxSpeed))
                    StatRow(label: L("detail.avg_speed"), value: formatSpeed(session.avgSpeed))
                    StatRow(label: L("detail.total_jumps"), value: "\(session.jumps.count)")
                }
                
                // GPS Route section
                if !session.gpsPoints.isEmpty {
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("detail.gps_route"))
                            .font(.headline)
                        
                        VStack(spacing: 8) {
                            StatRow(label: L("detail.gps_points"), value: "\(session.gpsPoints.count)")
                            StatRow(label: L("detail.route_distance"), value: formatDistance(session.distance))
                            StatRow(label: L("detail.avg_accuracy"), value: formatAccuracy(session.gpsPoints))
                            
                            // GPS coverage quality indicator
                            HStack {
                                Text(L("detail.gps_coverage"))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Spacer()
                                GPSCoverageBar(gpsPoints: session.gpsPoints, duration: session.duration)
                            }
                        }
                    }
                }
                
                // Jumps list
                if !session.jumps.isEmpty {
                    Divider()
                    
                    Text(L("session.jumps"))
                        .font(.headline)
                    
                    ForEach(session.jumps) { jump in
                        JumpCard(jump: jump)
                    }
                }
            }
            .padding()
        }
        // .watchScrollTopShadow()
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
        .navigationTitle(L("detail.session_complete"))
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    private func formatDistance(_ distance: Double) -> String {
        String(format: "%.2f km", distance / 1000.0)
    }
    
    private func formatSpeed(_ speed: Double) -> String {
        String(format: "%.1f km/h", speed * 3.6)
    }
    
    private func formatAccuracy(_ points: [GPSPoint]) -> String {
        guard !points.isEmpty else { return "--" }
        let avg = points.map { $0.horizontalAccuracy }.reduce(0, +) / Double(points.count)
        return String(format: "%.1f m", avg)
    }
}

struct StatRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            
            Spacer()
            
            Text(value)
                .font(.body)
                .fontWeight(.semibold)
        }
    }
}

struct JumpCard: View {
    let jump: Jump
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(format: "%.2f m", jump.height))
                    .font(.headline)
                
                Spacer()
                
                if jump.rotations > 0 {
                    Text("🔄 \(jump.rotations)")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            
            HStack {
                Text(jump.airtimeText(format: "%.2f sec"))
                    .font(.caption)
                    .foregroundColor(.gray)
                
                Spacer()
                
                // Confidence indicator
                HStack(spacing: 2) {
                    ForEach(0..<5) { i in
                        Circle()
                            .fill(i < Int(jump.confidence / 20) ? Color.green : Color.gray.opacity(0.3))
                            .frame(width: 4, height: 4)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(.darkGray))
        .cornerRadius(8)
    }
}

// GPS Coverage quality bar - shows what % of the session had GPS
struct GPSCoverageBar: View {
    let gpsPoints: [GPSPoint]
    let duration: TimeInterval
    
    private var coveragePercent: Double {
        // At 1Hz GPS, expected points = duration seconds
        guard duration > 0 else { return 0 }
        return min(1.0, Double(gpsPoints.count) / duration)
    }
    
    private var coverageColor: Color {
        if coveragePercent >= 0.8 { return .green }
        if coveragePercent >= 0.5 { return .yellow }
        return .orange
    }
    
    var body: some View {
        HStack(spacing: 4) {
            // Coverage bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.3))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(coverageColor)
                        .frame(width: geo.size.width * coveragePercent)
                }
            }
            .frame(width: 40, height: 6)
            
            Text("\(Int(coveragePercent * 100))%")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(coverageColor)
        }
    }
}

struct SessionDetailView_Previews: PreviewProvider {
    static var previews: some View {
        let session = Session(sport: .kiteboarding)
        SessionDetailView(session: session)
    }
}

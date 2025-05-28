import SwiftUI
import Foundation
import Network
import Combine

// MARK: - 数据模型
struct NetworkRequest: Identifiable, Codable {
    let id = UUID()
    let timestamp: Date
    let method: String
    let url: String
    let headers: [String: String]
    let body: String?
    var response: NetworkResponse?
    let startTime: Date
    
    init(method: String, url: String, headers: [String: String], body: String? = nil) {
        self.timestamp = Date()
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.startTime = Date()
    }
}

struct NetworkResponse: Codable {
    let statusCode: Int
    let headers: [String: String]
    let body: String?
    let duration: TimeInterval
    let size: Int
}

// MARK: - 网络拦截器
class NetworkInterceptor: NSObject, ObservableObject {
    @Published var capturedRequests: [NetworkRequest] = []
    
    static let shared = NetworkInterceptor()
    
    private override init() {
        super.init()
        setupURLProtocol()
    }
    
    private func setupURLProtocol() {
        URLProtocol.registerClass(NetworkCapturingURLProtocol.self)
    }
    
    func addRequest(_ request: NetworkRequest) {
        DispatchQueue.main.async {
            self.capturedRequests.insert(request, at: 0)
            // 限制存储数量
            if self.capturedRequests.count > 1000 {
                self.capturedRequests = Array(self.capturedRequests.prefix(1000))
            }
        }
    }
    
    func updateRequest(_ requestId: UUID, with response: NetworkResponse) {
        DispatchQueue.main.async {
            if let index = self.capturedRequests.firstIndex(where: { $0.id == requestId }) {
                self.capturedRequests[index].response = response
            }
        }
    }
    
    func clearRequests() {
        DispatchQueue.main.async {
            self.capturedRequests.removeAll()
        }
    }
}

// MARK: - 自定义 URLProtocol
class NetworkCapturingURLProtocol: URLProtocol {
    private var dataTask: URLSessionDataTask?
    private var capturedRequest: NetworkRequest?
    
    override class func canInit(with request: URLRequest) -> Bool {
        // 避免无限循环
        guard URLProtocol.property(forKey: "NetworkCapturingURLProtocol", in: request) == nil else {
            return false
        }
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "Invalid URL", code: -1))
            return
        }
        
        // 创建网络请求记录
        let headers = request.allHTTPHeaderFields ?? [:]
        let method = request.httpMethod ?? "GET"
        let bodyString = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        
        capturedRequest = NetworkRequest(
            method: method,
            url: url.absoluteString,
            headers: headers,
            body: bodyString
        )
        
        if let capturedRequest = capturedRequest {
            NetworkInterceptor.shared.addRequest(capturedRequest)
        }
        
        // 创建新的请求，添加标记避免重复拦截
        let mutableRequest = request.mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: "NetworkCapturingURLProtocol", in: mutableRequest)
        
        // 执行实际请求
        let session = URLSession(configuration: .default)
        dataTask = session.dataTask(with: mutableRequest as URLRequest) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                // 记录响应
                let responseHeaders = httpResponse.allHeaderFields.compactMapValues { "\($0)" }
                let responseBody = data.flatMap { String(data: $0, encoding: .utf8) }
                let duration = Date().timeIntervalSince(self.capturedRequest?.startTime ?? Date())
                
                let networkResponse = NetworkResponse(
                    statusCode: httpResponse.statusCode,
                    headers: responseHeaders,
                    body: responseBody,
                    duration: duration,
                    size: data?.count ?? 0
                )
                
                if let requestId = self.capturedRequest?.id {
                    NetworkInterceptor.shared.updateRequest(requestId, with: networkResponse)
                }
                
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            
            if let data = data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            
            self.client?.urlProtocolDidFinishLoading(self)
        }
        
        dataTask?.resume()
    }
    
    override func stopLoading() {
        dataTask?.cancel()
    }
}

// MARK: - 主界面
struct ContentView: View {
    @StateObject private var networkInterceptor = NetworkInterceptor.shared
    @State private var selectedRequest: NetworkRequest?
    @State private var showingRequestDetail = false
    @State private var testURL = "https://httpbin.org/get"
    
    var body: some View {
        NavigationView {
            VStack {
                // 统计信息
                HStack(spacing: 20) {
                    StatCard(title: "总请求", value: "\(networkInterceptor.capturedRequests.count)")
                    StatCard(title: "成功", value: "\(successCount)")
                    StatCard(title: "失败", value: "\(errorCount)")
                    StatCard(title: "平均耗时", value: "\(averageDuration)ms")
                }
                .padding()
                
                // 控制按钮
                HStack {
                    Button("🔄 刷新") {
                        // 刷新列表
                    }
                    .buttonStyle(.bordered)
                    
                    Button("🗑️ 清空") {
                        networkInterceptor.clearRequests()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("📤 导出") {
                        exportRequests()
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                }
                .padding(.horizontal)
                
                // 测试区域
                VStack {
                    HStack {
                        TextField("测试URL", text: $testURL)
                            .textFieldStyle(.roundedBorder)
                        
                        Button("发送请求") {
                            makeTestRequest()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal)
                
                // 请求列表
                List(networkInterceptor.capturedRequests) { request in
                    RequestRow(request: request)
                        .onTapGesture {
                            selectedRequest = request
                            showingRequestDetail = true
                        }
                }
            }
            .navigationTitle("🔨 网络调试器")
            .sheet(isPresented: $showingRequestDetail) {
                if let request = selectedRequest {
                    RequestDetailView(request: request)
                }
            }
        }
    }
    
    private var successCount: Int {
        networkInterceptor.capturedRequests.filter { 
            ($0.response?.statusCode ?? 0) < 400 
        }.count
    }
    
    private var errorCount: Int {
        networkInterceptor.capturedRequests.filter { 
            ($0.response?.statusCode ?? 0) >= 400 
        }.count
    }
    
    private var averageDuration: Int {
        let durations = networkInterceptor.capturedRequests.compactMap { $0.response?.duration }
        guard !durations.isEmpty else { return 0 }
        return Int(durations.reduce(0, +) / Double(durations.count) * 1000)
    }
    
    private func makeTestRequest() {
        guard let url = URL(string: testURL) else { return }
        
        URLSession.shared.dataTask(with: url) { _, _, _ in
            // 请求会被拦截器自动捕获
        }.resume()
    }
    
    private func exportRequests() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        if let data = try? encoder.encode(networkInterceptor.capturedRequests),
           let jsonString = String(data: data, encoding: .utf8) {
            
            let activityController = UIActivityViewController(
                activityItems: [jsonString],
                applicationActivities: nil
            )
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                window.rootViewController?.present(activityController, animated: true)
            }
        }
    }
}

// MARK: - 统计卡片
struct StatCard: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.blue)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - 请求行
struct RequestRow: View {
    let request: NetworkRequest
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // 方法标签
                Text(request.method)
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(methodColor)
                    .foregroundColor(.white)
                    .cornerRadius(4)
                
                Spacer()
                
                // 状态码
                if let response = request.response {
                    Text("\(response.statusCode)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(statusColor(response.statusCode))
                }
                
                // 时间
                Text(DateFormatter.timeFormatter.string(from: request.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // URL
            Text(request.url)
                .font(.body)
                .lineLimit(2)
            
            // 耗时和大小
            HStack {
                if let response = request.response {
                    Text("\(Int(response.duration * 1000))ms")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    Text(formatSize(response.size))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
    
    private var methodColor: Color {
        switch request.method {
        case "GET": return .green
        case "POST": return .blue
        case "PUT": return .orange
        case "DELETE": return .red
        default: return .gray
        }
    }
    
    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 300..<400: return .orange
        case 400..<500: return .red
        case 500...: return .purple
        default: return .gray
        }
    }
    
    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024)KB" }
        return "\(bytes / (1024 * 1024))MB"
    }
}

// MARK: - 请求详情视图
struct RequestDetailView: View {
    let request: NetworkRequest
    @State private var selectedTab = 0
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                // 标签切换
                Picker("选项", selection: $selectedTab) {
                    Text("请求").tag(0)
                    Text("响应").tag(1)
                    Text("请求头").tag(2)
                    Text("响应头").tag(3)
                }
                .pickerStyle(.segmented)
                .padding()
                
                // 内容区域
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch selectedTab {
                        case 0:
                            requestContent
                        case 1:
                            responseContent
                        case 2:
                            requestHeaders
                        case 3:
                            responseHeaders
                        default:
                            EmptyView()
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("请求详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var requestContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailRow(title: "方法", content: request.method)
            DetailRow(title: "URL", content: request.url)
            DetailRow(title: "时间", content: DateFormatter.fullFormatter.string(from: request.timestamp))
            
            if let body = request.body {
                VStack(alignment: .leading) {
                    Text("请求体")
                        .font(.headline)
                    Text(body)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                }
            }
        }
    }
    
    private var responseContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let response = request.response {
                DetailRow(title: "状态码", content: "\(response.statusCode)")
                DetailRow(title: "耗时", content: "\(Int(response.duration * 1000))ms")
                DetailRow(title: "大小", content: formatSize(response.size))
                
                if let body = response.body {
                    VStack(alignment: .leading) {
                        Text("响应体")
                            .font(.headline)
                        Text(body)
                            .font(.system(.body, design: .monospaced))
                            .padding()
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                    }
                }
            } else {
                Text("暂无响应数据")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var requestHeaders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("请求头")
                .font(.headline)
            
            ForEach(Array(request.headers.keys.sorted()), id: \.self) { key in
                DetailRow(title: key, content: request.headers[key] ?? "")
            }
        }
    }
    
    private var responseHeaders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("响应头")
                .font(.headline)
            
            if let response = request.response {
                ForEach(Array(response.headers.keys.sorted()), id: \.self) { key in
                    DetailRow(title: key, content: response.headers[key] ?? "")
                }
            } else {
                Text("暂无响应头数据")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024)KB" }
        return "\(bytes / (1024 * 1024))MB"
    }
}

// MARK: - 详情行组件
struct DetailRow: View {
    let title: String
    let content: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            Text(content)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}

// MARK: - App入口
@main
struct NetworkDebuggerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - 扩展
extension DateFormatter {
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()
    
    static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
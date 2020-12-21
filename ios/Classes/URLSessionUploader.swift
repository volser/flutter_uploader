//
//  URLSessionHolder.swift
//  flutter_uploader
//
//  Created by Sebastian Roth on 21/07/2020.
//

import Foundation

class URLSessionUploader: NSObject {
    public static let KEY_BACKGROUND_SESSION_IDENTIFIER = "chillisource.flutter_uploader.upload.background"

    fileprivate static let KEY_MAXIMUM_CONCURRENT_TASK = "FUMaximumConnectionsPerHost"
    fileprivate static let KEY_MAXIMUM_CONCURRENT_UPLOAD_OPERATION = "FUMaximumUploadOperation"
    fileprivate static let KEY_TIMEOUT_IN_SECOND = "FUTimeoutInSeconds"

    static let shared = URLSessionUploader()

    var session: URLSession?
    let queue = OperationQueue()

    // Reference for uploaded data.
    var uploadedData = [String: Data]()

    // Reference for currently running tasks.
    var runningTaskById = [String: UploadTask]()

    private var delegates: [UploaderDelegate] = []

    /// See the discussion on [application:handleEventsForBackgroundURLSession:completionHandler:](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/1622941-application?language=objc)
    public var backgroundTransferCompletionHander: (() -> Void)?

    // MARK: Public API

    func addDelegate(_ delegate: UploaderDelegate) {
        delegates.append(delegate)
    }

    func enqueueUploadTask(_ request: URLRequest, path: String) -> URLSessionUploadTask? {
        guard let session = self.session else {
            return nil
        }

        let uploadTask = session.uploadTask(with: request as URLRequest, fromFile: URL(fileURLWithPath: path))

        // Create a random UUID as task description (& ID).
        uploadTask.taskDescription = UUID().uuidString

        let taskId = identifierForTask(uploadTask)
        
        delegates.uploadEnqueued(taskId: taskId)

        uploadTask.resume()
        self.runningTaskById[taskId] = UploadTask(taskId: taskId, status: .enqueue, progress: 0)

        return uploadTask
    }

    ///
    /// The description on URLSessionTask.taskIdentifier explains how the task is only unique within a session.
    public func identifierForTask(_ task: URLSessionUploadTask) -> String {
        return  "\(self.session?.configuration.identifier ?? "chillisoure.flutter_uploader").\(task.taskDescription!)"
    }

    /// Cancel a task by ID. Complete with `true`/`false` depending on whether the task was running.
    func cancelWithTaskId(_ taskId: String) {
        guard let session = session else {
            return
        }

        session.getTasksWithCompletionHandler { (_, uploadTasks, _) in
            for uploadTask in uploadTasks {
                let state = uploadTask.state
                if self.identifierForTask(uploadTask) == taskId && state == .running {
                    self.delegates.uploadProgressed(taskId: taskId, inStatus: .canceled, progress: -1)

                    uploadTask.cancel()
                    return
                }
            }
        }
    }

    /// Cancel all running tasks & return the list of canceled tasks.
    func cancelAllTasks() {
        session?.getTasksWithCompletionHandler { (_, uploadTasks, _) in
            for uploadTask in uploadTasks {
                let state = uploadTask.state
                let taskId = self.identifierForTask(uploadTask)
                if state == .running {
                    self.delegates.uploadProgressed(taskId: taskId, inStatus: .canceled, progress: -1)

                    uploadTask.cancel()
                }
            }
        }
    }

    // MARK: Private API

    override init() {
        super.init()

        delegates.append(EngineManager())

        delegates.append(UploadResultDatabase.shared)

        self.queue.name = "chillisource.flutter_uploader.queue"

        let mainBundle = Bundle.main
        var maxConcurrentTasks: NSNumber
        if let concurrentTasks = mainBundle.object(forInfoDictionaryKey: URLSessionUploader.KEY_MAXIMUM_CONCURRENT_TASK) {
            maxConcurrentTasks = concurrentTasks as! NSNumber
        } else {
            maxConcurrentTasks = NSNumber(integerLiteral: 3)
        }

        NSLog("MAXIMUM_CONCURRENT_TASKS = \(maxConcurrentTasks)")

        var maxUploadOperation: NSNumber
        if let operationTask = mainBundle.object(forInfoDictionaryKey: URLSessionUploader.KEY_MAXIMUM_CONCURRENT_UPLOAD_OPERATION) {
            maxUploadOperation = operationTask as! NSNumber
        } else {
            maxUploadOperation = NSNumber(integerLiteral: 2)
        }

        NSLog("MAXIMUM_CONCURRENT_UPLOAD_OPERATION = \(maxUploadOperation)")

        self.queue.maxConcurrentOperationCount = maxUploadOperation.intValue

        let sessionConfiguration = URLSessionConfiguration.background(withIdentifier: URLSessionUploader.KEY_BACKGROUND_SESSION_IDENTIFIER)
        sessionConfiguration.httpMaximumConnectionsPerHost = maxConcurrentTasks.intValue
        sessionConfiguration.timeoutIntervalForRequest = URLSessionUploader.determineTimeout()
        self.session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: queue)
    }

    private static func determineTimeout() -> Double {
        if let timeoutSetting = Bundle.main.object(forInfoDictionaryKey: URLSessionUploader.KEY_TIMEOUT_IN_SECOND) {
            return (timeoutSetting as! NSNumber).doubleValue
        } else {
            return SwiftFlutterUploaderPlugin.DEFAULT_TIMEOUT
        }
    }
}

extension URLSessionUploader: URLSessionDelegate, URLSessionDataDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        NSLog("URLSessionDidReceiveData:")

        guard let uploadTask = dataTask as? URLSessionUploadTask else {
            NSLog("URLSessionDidReceiveData: not an uplaod task")
            return
        }

        if data.count > 0 {
            let taskId = identifierForTask(uploadTask)
            if var existing = uploadedData[taskId] {
                existing.append(data)
            } else {
                uploadedData[taskId] = Data(data)
            }
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        NSLog("URLSessionDidBecomeInvalidWithError:")
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        NSLog("URLSessionTaskIsWaitingForConnectivity:")
    }

//    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
//        if totalBytesExpectedToSend == NSURLSessionTransferSizeUnknown {
//            NSLog("Unknown transfer size")
//        } else {
//            guard let uploadTask = task as? URLSessionUploadTask else {
//                NSLog("URLSessionDidSendBodyData: an not uplaod task")
//                return
//            }
//
//            let taskId = identifierForTask(uploadTask)
//            let bytesExpectedToSend = Double(integerLiteral: totalBytesExpectedToSend)
//            let tBytesSent = Double(integerLiteral: totalBytesSent)
//            let progress = round(Double(tBytesSent / bytesExpectedToSend * 100))
//            let runningTask = self.runningTaskById[taskId]
//            NSLog("URLSessionDidSendBodyData: taskId: \(taskId), byteSent: \(bytesSent), totalBytesSent: \(totalBytesSent), totalBytesExpectedToSend: \(totalBytesExpectedToSend), progress:\(progress)")

//            if runningTask != nil {
//                let isRunning: (Int, Int, Int) -> Bool = {
//                    (current, previous, step) in
//                    let prev = previous + step
//                    return (current == 0 || current > prev || current >= 100) &&  current != previous
//                }
//
//                if isRunning(Int(progress), runningTask!.progress, SwiftFlutterUploaderPlugin.STEP_UPDATE) {
//                    self.delegates.uploadProgressed(taskId: taskId, inStatus: .running, progress: Int(progress))
//                    self.runningTaskById[taskId] = UploadTask(taskId: taskId, status: .running, progress: Int(progress), tag: runningTask?.tag)
//                }
//            }
//        }
//    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        NSLog("URLSessionDidFinishEvents:")
        session.getTasksWithCompletionHandler { (_, uploadTasks, _) in
            if uploadTasks.isEmpty {
                NSLog("all upload tasks have been completed")

                self.backgroundTransferCompletionHander?()
                self.backgroundTransferCompletionHander = nil
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let uploadTask = task as? URLSessionUploadTask else {
            NSLog("URLSessionDidCompleteWithError: not an uplaod task")
            return
        }

        let taskId = identifierForTask(uploadTask)

        if error != nil {
            NSLog("URLSessionDidCompleteWithError: \(taskId) failed with \(error!.localizedDescription)")
            var uploadStatus: UploadTaskStatus = .failed
            switch error! {
            case URLError.cancelled:
                uploadStatus = .canceled
            default:
                uploadStatus = .failed
            }

            self.delegates.uploadFailed(taskId: taskId, inStatus: uploadStatus, statusCode: 500, errorCode: "upload_error", errorMessage: error?.localizedDescription ?? "", errorStackTrace: Thread.callStackSymbols)
            self.runningTaskById.removeValue(forKey: taskId)
            self.uploadedData.removeValue(forKey: taskId)
            return
        }

        var hasResponseError = false
        var response: HTTPURLResponse?
        var statusCode = 500

        if task.response is HTTPURLResponse {
            response = task.response as? HTTPURLResponse

            if response != nil {
                NSLog("URLSessionDidCompleteWithError: \(taskId) with response: \(response!) and status: \(response!.statusCode)")
                statusCode = response!.statusCode
                hasResponseError = !isRequestSuccessful(response!.statusCode)
            }
        }

        NSLog("URLSessionDidCompleteWithError: upload completed")

        let headers = response?.allHeaderFields
        var responseHeaders = [String: Any]()
        if headers != nil {
            headers!.forEach { (key, value) in
                if let k = key as? String {
                    responseHeaders[k] = value
                }
            }
        }

        let message: String?
        if let data = uploadedData[taskId] {
            message = String(data: data, encoding: String.Encoding.utf8)
        } else {
            message = nil
        }

        if error == nil && !hasResponseError {
            NSLog("URLSessionDidCompleteWithError: response: \(message ?? "null"), task: \(uploadTask.state.statusText())")
            self.delegates.uploadCompleted(taskId: taskId, message: message, statusCode: response?.statusCode ?? 200, headers: responseHeaders)
        } else if hasResponseError {
            NSLog("URLSessionDidCompleteWithError: task: \(uploadTask.state.statusText()) statusCode: \(response?.statusCode ?? -1), error:\(message ?? "null"), response:\(String(describing: response))")
            self.delegates.uploadFailed(taskId: taskId, inStatus: .failed, statusCode: statusCode, errorCode: "upload_error", errorMessage: message, errorStackTrace: Thread.callStackSymbols)
        } else {
            NSLog("URLSessionDidCompleteWithError: task: \(uploadTask.state.statusText()) statusCode: \(response?.statusCode ?? -1), error:\(error?.localizedDescription ?? "none")")
            delegates.uploadFailed(taskId: taskId, inStatus: .failed, statusCode: statusCode, errorCode: "upload_error", errorMessage: error?.localizedDescription ?? "", errorStackTrace: Thread.callStackSymbols)
        }

        self.uploadedData.removeValue(forKey: taskId)
        self.runningTaskById.removeValue(forKey: taskId)
    }

    private func isRequestSuccessful(_ statusCode: Int) -> Bool {
        return statusCode >= 200 && statusCode <= 299
    }
}

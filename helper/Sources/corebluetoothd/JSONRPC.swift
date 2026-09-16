import Foundation

// Minimal JSON-RPC 2.0-ish envelope handling built on JSONSerialization for
// the envelope (id/method/params/result/error) and JSONEncoder/JSONDecoder
// for the strongly-typed payloads. This avoids needing a hand-rolled
// "any JSON value" Decodable type.
//
// Framing: each message is exactly one JSON object per line (newline-
// delimited). JSONSerialization's non-pretty-printed output never contains
// raw newlines, so this is safe.

enum RPCParseError: Error {
    case invalidJSON
    case missingMethod
}

struct IncomingRequest {
    /// Present for requests (Int/String, possibly wrapped in NSNumber), nil
    /// for JSON-RPC notifications sent by the client (unused by this
    /// server today, but accepted for spec-completeness).
    let id: Any?
    let method: String
    let paramsData: Data?
}

func parseIncoming(line: Data) throws -> IncomingRequest {
    guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        throw RPCParseError.invalidJSON
    }
    guard let method = obj["method"] as? String else {
        throw RPCParseError.missingMethod
    }
    let id = obj["id"]
    var paramsData: Data? = nil
    if let params = obj["params"] {
        paramsData = try? JSONSerialization.data(withJSONObject: params)
    }
    return IncomingRequest(id: id, method: method, paramsData: paramsData)
}

private let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    return encoder
}()

func makeResponseData<T: Encodable>(id: Any?, result: T) -> Data {
    let resultData = (try? jsonEncoder.encode(result)) ?? Data("{}".utf8)
    let resultObj = (try? JSONSerialization.jsonObject(with: resultData)) ?? [String: Any]()
    var obj: [String: Any] = [
        "jsonrpc": "2.0",
        "result": resultObj
    ]
    obj["id"] = id ?? NSNull()
    return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
}

func makeErrorResponseData(id: Any?, code: Int, message: String) -> Data {
    let obj: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id ?? NSNull(),
        "error": [
            "code": code,
            "message": message
        ]
    ]
    return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
}

func makeNotificationData<T: Encodable>(method: String, params: T) -> Data {
    let paramsData = (try? jsonEncoder.encode(params)) ?? Data("{}".utf8)
    let paramsObj = (try? JSONSerialization.jsonObject(with: paramsData)) ?? [String: Any]()
    let obj: [String: Any] = [
        "jsonrpc": "2.0",
        "method": method,
        "params": paramsObj
    ]
    return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
}

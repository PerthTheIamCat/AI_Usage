import Foundation

/// Fetches the live USD→THB rate for the Settings › Cost auto-fetch option.
/// Frankfurter (https://api.frankfurter.app) is free, keyless, and backed by
/// the ECB's daily reference rates — accurate enough for an estimated-cost
/// display without needing an account or secret to call.
enum ExchangeRateFetcher {
    private static let url = URL(string: "https://api.frankfurter.app/latest?from=USD&to=THB")!

    /// Calls back on the main queue with `nil` on any failure (offline, bad
    /// response, etc.) — callers should keep using the last-known rate.
    static func fetchUSDtoTHB(completion: @escaping (Double?) -> Void) {
        let req = URLRequest(url: url, timeoutInterval: 10)
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            guard err == nil,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rates = obj["rates"] as? [String: Any],
                  let thb = (rates["THB"] as? Double) ?? (rates["THB"] as? Int).map(Double.init)
            else {
                if let err { appLog("fx: rate fetch failed — \(err.localizedDescription)") }
                DispatchQueue.main.async { completion(nil) }
                return
            }
            appLog("fx: fetched USD→THB = \(thb)")
            DispatchQueue.main.async { completion(thb) }
        }
        task.resume()
    }
}

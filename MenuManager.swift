import Foundation

// Shared decode path for every menu source (server, cache, bundle):
// decode the v2 wire format, then validate and resolve station names.
private func decodeMenu(from data: Data) -> [Drink]? {
    do {
        let menu = try JSONDecoder().decode(DrinkMenu.self, from: data)
        return menu.resolvedDrinks()
    } catch {
        print("Error decoding menu JSON: \(error)")
        return nil
    }
}

func loadLocalDrinks() -> [Drink] {  //Load Drink
    if let url = Bundle.main.url(forResource: "drinks", withExtension: "json") {
        print("File path: \(url.path)")
        do {
            let data = try Data(contentsOf: url)
            if let drinks = decodeMenu(from: data) {
                return drinks
            }
        } catch {
            print("Error reading bundled menu: \(error)")
        }
    } else {
        print("File not found.")
    }
    return []
}

func downloadAndCacheMenu(completion: @escaping ([Drink]?) -> Void) {
    // v2 menu with station definitions; the old drinks.json stays on the
    // server so app versions that predate this format keep working
    let urlString = "https://www.grupomovic.com/mixtender/drinks_v2.json"
    
    guard let url = URL(string: urlString) else {
        print("Invalid URL")
        completion(nil)
        return
    }
    
    let urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60.0)
    let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
        var drinks: [Drink]? = nil

        if let error = error {
            print("Failed to download data: \(error)")
        } else if let data = data {
            drinks = decodeMenu(from: data)
            if drinks != nil {
                // Only cache data that decoded and validated successfully
                saveDataToCache(data: data)
            }
        } else {
            print("No data received")
        }

        // Callers update UI state, so deliver the result on the main thread
        DispatchQueue.main.async {
            completion(drinks)
        }
    }

    task.resume()
}

// Cached under the v2 name so a stale old-format drinks.json is never picked up
private let cachedMenuFileName = "drinks_v2.json"

func saveDataToCache(data: Data) {
    let fileManager = FileManager.default
    guard let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
        print("Failed to get cache directory")
        return
    }
    
    let fileURL = cacheDirectory.appendingPathComponent(cachedMenuFileName)
    
    do {
        try data.write(to: fileURL)
        print("Data saved to cache")
    } catch {
        print("Failed to save data to cache: \(error)")
    }
}


func getDrinksCachedFile() -> [Drink]? {
    let fileManager = FileManager.default
    guard let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
        print("Failed to get cache directory")
        return nil
    }
    
    let fileURL = cacheDirectory.appendingPathComponent(cachedMenuFileName)
    
    if fileManager.fileExists(atPath: fileURL.path) {
        print("Cached file found at: \(fileURL.path)")
        do {
            let data = try Data(contentsOf: fileURL)
            return decodeMenu(from: data)
        } catch {
            print("Failed to read cached file: \(error)")
            return nil
        }
    } else {
        print("No cached file found.")
        return nil
    }
}

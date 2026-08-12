import Foundation

func loadLocalDrinks() -> [Drink] {  //Load Drink
    if let url = Bundle.main.url(forResource: "drinks", withExtension: "json") {
        print("File path: \(url.path)")
        do {
            let data = try Data(contentsOf: url)
            let drinks = try JSONDecoder().decode([Drink].self, from: data)
            return drinks
        } catch {
            print("Error decoding JSON: \(error)")
        }
    } else {
        print("File not found.")
    }
    return []
}

func downloadAndCacheMenu(completion: @escaping ([Drink]?) -> Void) {
    // URL of the JSON file on the internet
    let urlString = "https://www.grupomovic.com/mixtender/drinks.json"
    
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
            do {
                drinks = try JSONDecoder().decode([Drink].self, from: data)
                // Only cache data that decoded successfully
                saveDataToCache(data: data)
            } catch {
                print("Error decoding JSON: \(error)")
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

func saveDataToCache(data: Data) {
    let fileManager = FileManager.default
    guard let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
        print("Failed to get cache directory")
        return
    }
    
    let fileURL = cacheDirectory.appendingPathComponent("drinks.json")
    
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
    
    let fileURL = cacheDirectory.appendingPathComponent("drinks.json")
    
    if fileManager.fileExists(atPath: fileURL.path) {
        print("Cached file found at: \(fileURL.path)")
        do {
            let data = try Data(contentsOf: fileURL)
//            return data
            let drinks = try JSONDecoder().decode([Drink].self, from: data)
            return drinks
        } catch {
            print("Failed to read cached file: \(error)")
            return nil
        }
    } else {
        print("No cached file found.")
        return nil
    }
}

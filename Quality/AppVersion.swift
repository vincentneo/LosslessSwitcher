import Cocoa
import Foundation

let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as! String
let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as! String

// MARK: - Localization Support

enum Language {
    case en
    case ja
    
    static var current: Language {
        if let preferred = Locale.preferredLanguages.first, preferred.hasPrefix("ja") {
            return .ja
        }
        return .en
    }
}

func localizedString(_ key: String) -> String {
    let translations: [String: [Language: String]] = [
        "Requires Privileges": [
            .en: "Requires Privileges",
            .ja: "管理者権限が必要です"
        ],
        "LosslessSwitcher requires Administrator privileges in order to detect each song's lossless sample rate in the Music app.": [
            .en: "LosslessSwitcher requires Administrator privileges in order to detect each song's lossless sample rate in the Music app.",
            .ja: "Musicアプリで各曲のロスレスサンプルレートを検出するためには、LosslessSwitcherに管理者権限が必要です。"
        ],
        "LosslessSwitcher could not check if your account has Administrator privileges. If your account lacks Administrator privileges, sample rate detection will not work.": [
            .en: "LosslessSwitcher could not check if your account has Administrator privileges. If your account lacks Administrator privileges, sample rate detection will not work.",
            .ja: "アカウントに管理者権限があるか確認できませんでした。管理者権限がない場合、サンプルレートの検出は動作しません。"
        ],
        "Bit Depth Switching": [
            .en: "Bit Depth Switching",
            .ja: "ビット深度の切り替え"
        ],
        "Prefer Closest Sample Rate Multiple": [
            .en: "Prefer Closest Sample Rate Multiple",
            .ja: "最も近いサンプルレートの倍数を優先"
        ],
        "Follow Quality Upgrades Mid-Song (Causes Interruption)": [
            .en: "Follow Quality Upgrades Mid-Song (Causes Interruption)",
            .ja: "ストリーミング中に品質が上がった場合追従させる（再生中に音切れ発生）"
        ],
        "Default Device": [
            .en: "Default Device",
            .ja: "デフォルトのデバイス"
        ],
        "Selected Device": [
            .en: "Selected Device",
            .ja: "選択されたデバイス"
        ],
        "About": [
            .en: "About",
            .ja: "このアプリについて"
        ],
        "Version": [
            .en: "Version",
            .ja: "バージョン"
        ],
        "Build": [
            .en: "Build",
            .ja: "ビルド"
        ],
        "Scripting": [
            .en: "Scripting",
            .ja: "スクリプト処理"
        ],
        "Select Script...": [
            .en: "Select Script...",
            .ja: "スクリプトを選択..."
        ],
        "Clear Selection": [
            .en: "Clear Selection",
            .ja: "選択解除"
        ],
        "No selection": [
            .en: "No selection",
            .ja: "未選択"
        ],
        "Quit LosslessSwitcher": [
            .en: "Quit LosslessSwitcher",
            .ja: "LosslessSwitcherを終了"
        ],
        "Select a script that should be invoked when sample rate changes.": [
            .en: "Select a script that should be invoked when sample rate changes.",
            .ja: "サンプルレートが変更されたときに呼び出すスクリプトを選択してください。"
        ],
        "Show Sample Rate": [
            .en: "Show Sample Rate",
            .ja: "サンプルレートを表示"
        ],
        "Show Icon": [
            .en: "Show Icon",
            .ja: "アイコンを表示"
        ],
        "Update Available": [
            .en: "Update Available",
            .ja: "アップデートがあります"
        ],
        "A new version (%@) is available. Your current version is %@. Would you like to download it?": [
            .en: "A new version (%@) is available. Your current version is %@. Would you like to download it?",
            .ja: "新しいバージョン (%@) が利用可能です。現在のバージョンは %@ です。ダウンロードしますか？"
        ],
        "Update Now": [
            .en: "Update Now",
            .ja: "今すぐアップデート"
        ],
        "View on GitHub": [
            .en: "View on GitHub",
            .ja: "GitHubで確認"
        ],
        "Downloading update...": [
            .en: "Downloading update...",
            .ja: "アップデートをダウンロード中..."
        ],
        "Installing update and restarting...": [
            .en: "Installing update and restarting...",
            .ja: "アップデートを適用して再起動中..."
        ],
        "Update Failed": [
            .en: "Update Failed",
            .ja: "アップデートに失敗しました"
        ],
        "Download": [
            .en: "Download",
            .ja: "ダウンロード"
        ],
        "Later": [
            .en: "Later",
            .ja: "後で"
        ],
        "Mid-Song Quality Switching": [
            .en: "Mid-Song Quality Switching",
            .ja: "曲中の音質変更（ストリーミング昇格）"
        ],
        "Wait Until Next Track (Recommended)": [
            .en: "Wait Until Next Track (Recommended)",
            .ja: "次の曲まで待機（推奨・音切れ防止）"
        ],
        "Switch Immediately (Causes Interruption)": [
            .en: "Switch Immediately (Causes Interruption)",
            .ja: "即時切り替え（再生中に音切れ・巻き戻し発生）"
        ],
        "Mid-Song Quality": [
            .en: "Mid-Song Quality",
            .ja: "曲中音質変更"
        ],
        "Wait (Recommended)": [
            .en: "Wait (Recommended)",
            .ja: "次曲まで待機（推奨）"
        ],
        "Immediate (Interrupts)": [
            .en: "Immediate (Interrupts)",
            .ja: "即時追従（音切れあり）"
        ],
        "Up to Date": [
            .en: "Up to Date",
            .ja: "最新の状態です"
        ],
        "LosslessSwitcher is up to date (v%@ is the latest version).": [
            .en: "LosslessSwitcher is up to date (v%@ is the latest version).",
            .ja: "LosslessSwitcherは最新の状態です (v%@ が最新バージョンです)。"
        ],
        "Check Failed": [
            .en: "Check Failed",
            .ja: "チェックに失敗しました"
        ],
        "Could not check for updates: %@": [
            .en: "Could not check for updates: %@",
            .ja: "アップデートの確認ができませんでした: %@"
        ],
        "OK": [
            .en: "OK",
            .ja: "OK"
        ],
        "Check for Updates...": [
            .en: "Check for Updates...",
            .ja: "アップデートを確認..."
        ],
        "Checking for updates...": [
            .en: "Checking for updates...",
            .ja: "アップデートを確認中..."
        ],
        "Unknown": [
            .en: "Unknown",
            .ja: "不明"
        ],
        "No releases found on GitHub.": [
            .en: "No releases found on GitHub.",
            .ja: "GitHub上にリリースが見つかりませんでした。"
        ]
    ]
    
    let lang = Language.current
    if let entry = translations[key], let val = entry[lang] {
        return val
    }
    return key
}

extension String {
    var localized: String {
        return localizedString(self)
    }
}

// MARK: - Update Checker

struct GitHubAsset: Codable {
    let name: String
    let browserDownloadUrl: String
    
    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

struct GitHubRelease: Codable {
    let tagName: String
    let htmlUrl: String
    let assets: [GitHubAsset]?
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case assets
    }
}

class UpdateChecker: ObservableObject {
    @Published var isChecking = false
    @Published var isUpdating = false
    
    static let shared = UpdateChecker()
    
    private init() {}
    
    func checkForUpdates(manually: Bool = false) {
        guard !isChecking && !isUpdating else { return }
        isChecking = true
        
        guard let url = URL(string: "https://api.github.com/repos/horikei525/LosslessSwitcher/releases/latest") else {
            isChecking = false
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("LosslessSwitcher-UpdateChecker", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            defer {
                DispatchQueue.main.async {
                    self.isChecking = false
                }
            }
            
            if let error = error {
                if manually {
                    self.showErrorAlert(error: error.localizedDescription)
                }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                if manually {
                    let errorMsg = httpResponse.statusCode == 404 ? "No releases found on GitHub.".localized : "HTTP Status \(httpResponse.statusCode)"
                    self.showErrorAlert(error: errorMsg)
                }
                return
            }
            
            guard let data = data else {
                if manually {
                    self.showErrorAlert(error: "No data received".localized)
                }
                return
            }
            
            do {
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let latest = release.tagName.replacingOccurrences(of: "v", with: "")
                let current = currentVersion
                
                let hasUpdate = self.isVersion(latest, newerThan: current)
                
                if hasUpdate {
                    self.showUpdateAlert(latest: latest, release: release)
                } else if manually {
                    self.showUpToDateAlert()
                }
            } catch {
                if manually {
                    self.showErrorAlert(error: error.localizedDescription)
                }
            }
        }.resume()
    }
    
    private func isVersion(_ version1: String, newerThan version2: String) -> Bool {
        if version1 == version2 { return false }
        
        let clean1 = version1.components(separatedBy: CharacterSet.decimalDigits.inverted.subtracting(CharacterSet(charactersIn: "."))).joined()
        let clean2 = version2.components(separatedBy: CharacterSet.decimalDigits.inverted.subtracting(CharacterSet(charactersIn: "."))).joined()
        
        let v1Components = clean1.split(separator: ".").compactMap { Int($0) }
        let v2Components = clean2.split(separator: ".").compactMap { Int($0) }
        
        let count = max(v1Components.count, v2Components.count)
        for i in 0..<count {
            let v1 = i < v1Components.count ? v1Components[i] : 0
            let v2 = i < v2Components.count ? v2Components[i] : 0
            if v1 > v2 {
                return true
            } else if v1 < v2 {
                return false
            }
        }
        
        let v1IsBeta = version1.lowercased().contains("beta") || version1.lowercased().contains("alpha")
        let v2IsBeta = version2.lowercased().contains("beta") || version2.lowercased().contains("alpha")
        
        if v1IsBeta && !v2IsBeta {
            return false
        }
        if !v1IsBeta && v2IsBeta {
            return true
        }
        
        return version1.compare(version2, options: .numeric) == .orderedDescending
    }
    
    private func showUpdateAlert(latest: String, release: GitHubRelease) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Update Available".localized
            alert.informativeText = String(format: "A new version (%@) is available. Your current version is %@. Would you like to download it?".localized, latest, currentVersion)
            
            alert.addButton(withTitle: "Update Now".localized)
            alert.addButton(withTitle: "View on GitHub".localized)
            alert.addButton(withTitle: "Later".localized)
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // Find matching asset: prefer .zip, then .dmg
                if let assets = release.assets,
                   let chosenAsset = assets.first(where: { $0.name.hasSuffix(".zip") }) ?? assets.first(where: { $0.name.hasSuffix(".dmg") }) {
                    self.performInAppUpdate(asset: chosenAsset)
                } else if let url = URL(string: release.htmlUrl) {
                    NSWorkspace.shared.open(url)
                }
            } else if response == .alertSecondButtonReturn {
                if let url = URL(string: release.htmlUrl) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    private func performInAppUpdate(asset: GitHubAsset) {
        guard let downloadUrl = URL(string: asset.browserDownloadUrl) else { return }
        
        DispatchQueue.main.async {
            self.isUpdating = true
        }
        
        let task = URLSession.shared.downloadTask(with: downloadUrl) { [weak self] tempLocalUrl, response, error in
            guard let self = self else { return }
            
            if let error = error {
                DispatchQueue.main.async {
                    self.isUpdating = false
                    self.showErrorAlert(error: error.localizedDescription)
                }
                return
            }
            
            guard let tempLocalUrl = tempLocalUrl else {
                DispatchQueue.main.async {
                    self.isUpdating = false
                    self.showErrorAlert(error: "Downloaded file not found".localized)
                }
                return
            }
            
            // Move downloaded file to /tmp
            let ext = asset.name.hasSuffix(".dmg") ? "dmg" : "zip"
            let targetDownloadPath = "/tmp/LosslessSwitcher_Update.\(ext)"
            let targetUrl = URL(fileURLWithPath: targetDownloadPath)
            try? FileManager.default.removeItem(at: targetUrl)
            
            do {
                try FileManager.default.moveItem(at: tempLocalUrl, to: targetUrl)
            } catch {
                DispatchQueue.main.async {
                    self.isUpdating = false
                    self.showErrorAlert(error: error.localizedDescription)
                }
                return
            }
            
            let isDMG = (ext == "dmg")
            self.runUpdaterScriptAndRelaunch(archivePath: targetDownloadPath, isDMG: isDMG)
        }
        
        task.resume()
    }
    
    private func runUpdaterScriptAndRelaunch(archivePath: String, isDMG: Bool) {
        let currentPid = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundleURL.path
        let updaterScriptPath = "/tmp/lossless_switcher_updater.sh"
        
        let scriptContent = """
        #!/bin/bash
        PID=\(currentPid)
        ARCHIVE_PATH="\(archivePath)"
        TARGET_APP_PATH="\(bundlePath)"
        IS_DMG="\(isDMG ? "true" : "false")"
        
        # Wait for caller application to exit
        for i in {1..30}; do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 0.5
        done
        
        TEMP_DIR=$(mktemp -d /tmp/ls_update_XXXXXX)
        EXTRACTED_APP=""
        
        if [ "$IS_DMG" = "true" ]; then
            MOUNT_DIR=$(mktemp -d /tmp/ls_mount_XXXXXX)
            hdiutil attach "$ARCHIVE_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -quiet -noautoopen 2>/dev/null || true
            FOUND_APP=$(find "$MOUNT_DIR" -maxdepth 2 -name "LosslessSwitcher.app" -o -name "*.app" | head -n 1)
            if [ -n "$FOUND_APP" ]; then
                cp -R "$FOUND_APP" "$TEMP_DIR/"
                EXTRACTED_APP="$TEMP_DIR/$(basename "$FOUND_APP")"
            fi
            hdiutil detach "$MOUNT_DIR" -quiet -force 2>/dev/null || true
            rm -rf "$MOUNT_DIR"
        else
            ditto -xk "$ARCHIVE_PATH" "$TEMP_DIR"
            FOUND_APP=$(find "$TEMP_DIR" -maxdepth 2 -name "LosslessSwitcher.app" -o -name "*.app" | head -n 1)
            if [ -n "$FOUND_APP" ]; then
                EXTRACTED_APP="$FOUND_APP"
            fi
        fi
        
        # Replace existing app bundle
        if [ -n "$EXTRACTED_APP" ] && [ -d "$EXTRACTED_APP" ]; then
            rm -rf "$TARGET_APP_PATH"
            cp -R "$EXTRACTED_APP" "$TARGET_APP_PATH"
        fi
        
        # Cleanup
        rm -rf "$TEMP_DIR"
        rm -f "$ARCHIVE_PATH"
        
        # Relaunch
        open "$TARGET_APP_PATH"
        rm -f "$0"
        """
        
        do {
            try scriptContent.write(toFile: updaterScriptPath, atomically: true, encoding: .utf8)
            let chmodProcess = Process()
            chmodProcess.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmodProcess.arguments = ["+x", updaterScriptPath]
            try chmodProcess.run()
            chmodProcess.waitUntilExit()
            
            let updaterProcess = Process()
            updaterProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
            updaterProcess.arguments = [updaterScriptPath]
            try updaterProcess.run()
            
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        } catch {
            DispatchQueue.main.async {
                self.isUpdating = false
                self.showErrorAlert(error: error.localizedDescription)
            }
        }
    }
    
    private func showUpToDateAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Up to Date".localized
            alert.informativeText = String(format: "LosslessSwitcher is up to date (v%@ is the latest version).".localized, currentVersion)
            alert.addButton(withTitle: "OK".localized)
            alert.runModal()
        }
    }
    
    private func showErrorAlert(error: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Check Failed".localized
            alert.informativeText = String(format: "Could not check for updates: %@".localized, error)
            alert.addButton(withTitle: "OK".localized)
            alert.runModal()
        }
    }
}

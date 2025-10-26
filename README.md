# Shrink-DockerVHD 說明文件

## 0. 專案介紹

這個專案的目的是 **釋放 Docker Desktop 在 WSL2 下佔用的磁碟空間**。
由於 Docker Desktop 在 Windows 上運行時，所有容器與映像檔都儲存在一個虛擬硬碟檔案（`docker_data.vhdx`）裡，即使刪除了容器或 image，檔案大小也不會自動縮小。
這個專案提供一個 **自動化腳本（PowerShell + 批次檔啟動器）**，可以：

* 清理 Docker 不再使用的資源（可選）。
* 對 `docker_data.vhdx` 執行壓縮（Optimize-VHD 或 DiskPart）。
* 自動比對壓縮前後容量，並輸出節省空間的統計。
* 自動記錄 log，方便追蹤操作紀錄。
* 提供自動提權機制，避免手動以管理員身分執行。

這讓你能夠定期維護 Docker 環境，避免 `C:\Users\<username>\AppData\Local\Docker\wsl\disk\docker_data.vhdx` 無限制增長，佔用大量 SSD/HDD 空間。

## 1. 腳本組成

這個方案包含兩個檔案：

1. **Shrink-DockerVHD.ps1**

   * PowerShell 腳本，負責實際壓縮 Docker Desktop 的 VHDX 檔案（例如 `docker_data.vhdx`）。
   * 提供前後容量統計，並自動記錄到 log。
   * 預設會在 `%TEMP%` 目錄生成 log 檔案，例如：

     ```
     C:\Users\<username>\AppData\Local\Temp\Shrink-DockerVHD_20251026_170804.log
     ```
   * 參數：

     * `-Path <file>` → 指定要壓縮的 VHDX 檔案。
     * `-OpenLog` → 壓縮完成後自動開啟 log。

2. **Run-Shrink-DockerVHD.bat**

   * 批次檔啟動器，用來自動檢查與提升權限（UAC 提示）。
   * 不需要手動右鍵「以系統管理員身分執行」，雙擊即可自動提權並執行 `Shrink-DockerVHD.ps1`。
   * 最後會停留在視窗等待你按下 Enter，避免秒關。

---

## 2. 使用方法

1. 將 `Shrink-DockerVHD.ps1` 與 `Run-Shrink-DockerVHD.bat` 放在**同一個資料夾**（例如 `Desktop\Shrink-DockerVHD\`）。
2. 直接**雙擊 `Run-Shrink-DockerVHD.bat`**。

   * 若需要管理員權限，會跳出 UAC 視窗，允許即可。
   * 腳本會自動執行壓縮並生成 log。
   * 視窗不會自動關閉，會停在「Press Enter to close...」等你按 Enter。

---

## 3. 額外的 Docker 清理建議

在壓縮 VHDX 前，先清理 Docker 不必要的資料可以得到更佳效果：

在 **WSL2 shell** 或 Docker Desktop CLI 執行：

```sh
docker system prune -a --volumes
```

這會刪除：

* 未使用的映像檔（images）
* 停止的容器（stopped containers）
* 未使用的網路（networks）
* 建置快取（build cache）
* 未使用的 volumes

⚠️ 注意：刪除後若要再用到某些 image，可能需要重新拉取。

---

## 4. 執行結果

執行完成後，log 會顯示：

* 原始容量（Before）
* 壓縮後容量（After）
* 節省容量（Saved）

例如：

```
[INFO] Before: 48.6 GB
[INFO] After: 32.1 GB
[INFO] Saved: 16.5 GB
```

---

## 5. 常見問題

* **視窗一閃即關**
  → 使用 `Run-Shrink-DockerVHD.bat` 啟動，不要直接雙擊 `.ps1`。
* **執行策略限制**
  → 在 PowerShell 手動允許：

  ```powershell
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
  ```
* **Optimize-VHD 指令不可用**
  → 腳本會自動 fallback 到 DiskPart，不影響功能。
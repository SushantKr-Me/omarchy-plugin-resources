import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Resources Pro (Resources+): Complete System Resource Monitor & Hardware Telemetry.
// Features: Compact 6-track micro-meters in the bar, rich live hover tooltips,
// full popout interactive dashboard (Overview, Processes, Sensors, Disks),
// per-core load telemetry, quick process killer, cache trimmer, and multi-GPU telemetry.
Panel {
  id: root
  moduleName: "sushantkr.resources"
  ipcTarget: "sushantkr.resources"

  readonly property color barFg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color barUrgent: root.bar ? root.bar.urgent : Commons.Color.urgent
  readonly property color accentColor: Commons.Color.accent
  readonly property string barFont: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property bool vertical: root.bar ? root.bar.vertical : false

  implicitWidth: barItem.implicitWidth
  implicitHeight: barItem.implicitHeight

  readonly property string telemetryScript: String(Qt.resolvedUrl("scripts/telemetry.py")).replace(/^file:\/\//, "")
  readonly property string killScript: String(Qt.resolvedUrl("scripts/kill-proc.py")).replace(/^file:\/\//, "")
  readonly property string cleanScript: String(Qt.resolvedUrl("scripts/clean-cache.sh")).replace(/^file:\/\//, "")

  // Live Telemetry State
  property real cpuPercent: 0
  property real cpuTemp: 0
  property int cpuAvgFreq: 0
  property string cpuModel: "Processor"
  property var corePercents: []
  property int cpuHotStreak: 0
  readonly property int cpuHotAt: 80
  readonly property int cpuHotSamples: 3

  property real ramTotalKb: 1
  property real ramUsedKb: 0
  property real ramAvailKb: 0
  property real ramPercent: 0
  property real cachedKb: 0
  property real buffersKb: 0
  property real swapTotalKb: 0
  property real swapUsedKb: 0
  property real swapPercent: 0
  readonly property int ramHotAt: 80

  property bool gpuAvailable: false
  property string gpuName: "GPU"
  property real gpuPercent: 0
  property real gpuTemp: 0
  property var gpuList: []
  readonly property int gpuHotAt: 80

  property real diskPercent: 0
  property real diskTotalBytes: 0
  property real diskUsedBytes: 0
  property real diskFreeBytes: 0
  property string diskReadSpeed: "0 B/s"
  property string diskWriteSpeed: "0 B/s"
  readonly property int diskHotAt: 85

  property string netDownSpeed: "0 B/s"
  property string netUpSpeed: "0 B/s"
  property int netDownPercent: 0
  property var netInterfaces: []

  property var sensorTemps: []
  property var sensorFans: []
  property var systemOverview: ({ hostname: "localhost", kernel: "", uptime_str: "" })
  property var mounts: []
  property var procsByCpu: []
  property var procsByMem: []

  // Internal deltas
  property real prevTotal: -1
  property real prevIdle: -1
  property var prevCores: []
  property real prevDiskRead: -1
  property real prevDiskWrite: -1
  property real prevDiskTime: -1
  property real prevRxBytes: -1
  property real prevTxBytes: -1
  property real prevNetTime: -1

  // UI State
  property string currentTab: "overview" // "overview", "procs", "sensors", "disks"
  property string procFilter: "cpu" // "cpu", "mem", "win"
  property string searchQuery: ""
  property string statusMessage: ""
  property int killingPid: -1
  property bool isTrimming: false

  // Bar Meters
  readonly property color meterColor: root.barFg
  readonly property color urgentColor: root.barUrgent

  readonly property var meters: [
    { name: "CPU", value: cpuPercent, hot: cpuHotStreak >= cpuHotSamples, shown: true, icon: "󰻠" },
    { name: "RAM", value: ramPercent, hot: ramPercent >= ramHotAt, shown: true, icon: "󰍛" },
    { name: "SWP", value: swapPercent, hot: swapPercent >= 60, shown: swapTotalKb > 0, icon: "󰾴" },
    { name: "GPU", value: gpuPercent, hot: gpuPercent >= gpuHotAt, shown: gpuAvailable, icon: "󰢮" },
    { name: "DSK", value: diskPercent, hot: diskPercent >= diskHotAt, shown: true, icon: "󰋊" },
    { name: "NET", value: netDownPercent, hot: netDownPercent >= 75, shown: true, icon: "󰖩" }
  ]

  // Formatter helpers
  function formatKb(kb) {
    var mb = kb / 1024.0
    if (mb >= 1024) return (mb / 1024.0).toFixed(1) + " GB"
    if (mb >= 10) return mb.toFixed(0) + " MB"
    return mb.toFixed(1) + " MB"
  }

  function formatBytes(b) {
    var mb = b / (1024.0 * 1024.0)
    if (mb >= 1024) return (mb / 1024.0).toFixed(1) + " GB"
    if (mb >= 1) return mb.toFixed(1) + " MB"
    return Math.round(b / 1024.0) + " KB"
  }

  function formatBytesSpeed(bps) {
    var kb = bps / 1024.0
    if (kb >= 1024) return (kb / 1024.0).toFixed(1) + " MB/s"
    if (kb >= 10) return Math.round(kb) + " KB/s"
    if (kb >= 1) return kb.toFixed(1) + " KB/s"
    return Math.round(bps) + " B/s"
  }

  function parseTelemetry(raw) {
    try {
      var data = JSON.parse(raw)

      // CPU
      if (data.cpu && data.cpu.overall) {
        var tot = data.cpu.overall.total
        var idl = data.cpu.overall.idle
        if (root.prevTotal >= 0) {
          var dTot = tot - root.prevTotal
          var dIdl = idl - root.prevIdle
          if (dTot > 0) root.cpuPercent = Math.max(0, Math.min(100, Math.round(100.0 * (1.0 - dIdl / dTot))))
          root.cpuHotStreak = root.cpuPercent >= root.cpuHotAt ? root.cpuHotStreak + 1 : 0
        }
        root.prevTotal = tot
        root.prevIdle = idl
      }

      // Per Core
      if (data.cpu && data.cpu.cores) {
        var coreList = []
        for (var i = 0; i < data.cpu.cores.length; i++) {
          var c = data.cpu.cores[i]
          var prev = (root.prevCores && root.prevCores[i]) ? root.prevCores[i] : { total: 0, idle: 0 }
          var dt = c.total - prev.total
          var di = c.idle - prev.idle
          var pct = dt > 0 ? Math.max(0, Math.min(100, Math.round(100.0 * (1.0 - di / dt)))) : 0
          coreList.push({ id: c.id, percent: pct })
        }
        root.prevCores = data.cpu.cores
        if (root.prevTotal >= 0) root.corePercents = coreList
      }

      if (data.cpu) {
        root.cpuModel = data.cpu.model || "Processor"
        root.cpuAvgFreq = data.cpu.avg_freq_mhz || 0
      }

      // Mem
      if (data.mem) {
        root.ramTotalKb = data.mem.total_kb || 1
        root.ramUsedKb = data.mem.used_kb || 0
        root.ramAvailKb = data.mem.avail_kb || 0
        root.ramPercent = Math.round(data.mem.used_percent || 0)
        root.cachedKb = data.mem.cached_kb || 0
        root.buffersKb = data.mem.buffers_kb || 0
        root.swapTotalKb = data.mem.swap_total_kb || 0
        root.swapUsedKb = data.mem.swap_used_kb || 0
        root.swapPercent = Math.round(data.mem.swap_percent || 0)
      }

      // GPU
      if (data.gpu) {
        root.gpuAvailable = Boolean(data.gpu.available)
        root.gpuList = data.gpu.list || []
        if (data.gpu.primary) {
          root.gpuPercent = Math.round(data.gpu.primary.util_percent || 0)
          root.gpuTemp = data.gpu.primary.temp_c || 0
          root.gpuName = data.gpu.primary.name || "GPU"
        }
      }

      // Disk
      if (data.disk) {
        if (data.disk.root) {
          root.diskPercent = Math.round(data.disk.root.used_percent || 0)
          root.diskTotalBytes = data.disk.root.total_bytes || 0
          root.diskUsedBytes = data.disk.root.used_bytes || 0
          root.diskFreeBytes = data.disk.root.free_bytes || 0
        }
        var nowDisk = Date.now()
        if (root.prevDiskTime > 0 && nowDisk > root.prevDiskTime) {
          var dtDiskSec = (nowDisk - root.prevDiskTime) / 1000.0
          if (dtDiskSec > 0.3) {
            var dRead = Math.max(0, data.disk.io_read_bytes - root.prevDiskRead) / dtDiskSec
            var dWrite = Math.max(0, data.disk.io_write_bytes - root.prevDiskWrite) / dtDiskSec
            root.diskReadSpeed = root.formatBytesSpeed(dRead)
            root.diskWriteSpeed = root.formatBytesSpeed(dWrite)
          }
        }
        root.prevDiskRead = data.disk.io_read_bytes
        root.prevDiskWrite = data.disk.io_write_bytes
        root.prevDiskTime = nowDisk
      }

      // Network
      if (data.net) {
        var nowNet = Date.now()
        if (root.prevNetTime > 0 && nowNet > root.prevNetTime) {
          var dtNetSec = (nowNet - root.prevNetTime) / 1000.0
          if (dtNetSec > 0.3) {
            var dRx = Math.max(0, data.net.rx_total_bytes - root.prevRxBytes) / dtNetSec
            var dTx = Math.max(0, data.net.tx_total_bytes - root.prevTxBytes) / dtNetSec
            root.netDownSpeed = root.formatBytesSpeed(dRx)
            root.netUpSpeed = root.formatBytesSpeed(dTx)
            // Pulse: 5 MB/s = 100% full scale
            root.netDownPercent = Math.min(100, Math.round((dRx / (5 * 1024 * 1024)) * 100))
          }
        }
        root.prevRxBytes = data.net.rx_total_bytes
        root.prevTxBytes = data.net.tx_total_bytes
        root.prevNetTime = nowNet
        root.netInterfaces = data.net.interfaces || []
      }

      // Sensors
      if (data.sensors) {
        root.cpuTemp = Math.round(data.sensors.cpu_temp_c || root.cpuTemp)
        root.sensorTemps = data.sensors.temps || []
        root.sensorFans = data.sensors.fans || []
      }

      // Full mode payload
      if (data.system) root.systemOverview = data.system
      if (data.mounts) root.mounts = data.mounts
      if (data.processes) {
        root.procsByCpu = data.processes.by_cpu || []
        root.procsByMem = data.processes.by_mem || []
      }
    } catch (e) {
      // Ignored
    }
  }

  // Action runners
  function refresh() {
    if (!telemetryProc.running) telemetryProc.running = true
  }

  function killProcess(pid, name) {
    root.killingPid = pid
    killProc.command = [root.killScript, String(pid)]
    killProc.running = true
  }

  function cleanCache() {
    root.isTrimming = true
    root.statusMessage = "Trimming system caches..."
    cleanProc.running = true
  }

  function openActivity() {
    if (root.bar) root.bar.run("omarchy-launch-or-focus-tui btop")
  }

  function openHtop() {
    if (root.bar) root.bar.run("omarchy-launch-or-focus-tui htop")
  }

  function getDisplayProcesses() {
    var baseList = []
    if (root.procFilter === "cpu") {
      baseList = root.procsByCpu
    } else if (root.procFilter === "mem") {
      baseList = root.procsByMem
    } else if (root.procFilter === "win") {
      baseList = root.procsByCpu.filter(function(p) { return p.is_window })
    }

    if (!root.searchQuery || root.searchQuery.trim() === "") return baseList

    var query = root.searchQuery.toLowerCase().trim()
    return baseList.filter(function(p) {
      return (p.name && p.name.toLowerCase().indexOf(query) !== -1) ||
             (p.comm && p.comm.toLowerCase().indexOf(query) !== -1) ||
             (p.win_title && p.win_title.toLowerCase().indexOf(query) !== -1) ||
             String(p.pid).indexOf(query) !== -1
    })
  }

  Component.onCompleted: refresh()
  onOpenedChanged: {
    if (opened) {
      statusMessage = ""
      refresh()
    }
  }

  // Telemetry Subprocess
  Process {
    id: telemetryProc
    command: [root.telemetryScript, root.opened ? "--full" : "--summary"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseTelemetry(text)
    }
  }

  // Process Killer Subprocess
  Process {
    id: killProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.killingPid = -1
        try {
          var res = JSON.parse(text)
          if (res.success) {
            root.statusMessage = "Terminated " + (res.name || "process") + " (PID " + res.pid + ")"
            statusResetTimer.restart()
          } else {
            root.statusMessage = "Failed: " + (res.error || "Permission denied")
            statusResetTimer.restart()
          }
        } catch (e) {
          root.statusMessage = "Process signal sent"
        }
        root.refresh()
      }
    }
  }

  // Cache Trim Subprocess
  Process {
    id: cleanProc
    command: [root.cleanScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.isTrimming = false
        root.statusMessage = "Caches trimmed & memory compacted"
        statusResetTimer.restart()
        root.refresh()
      }
    }
  }

  // Refresh Timers
  Timer {
    interval: root.opened ? 1500 : 4000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: statusResetTimer
    interval: 4000
    onTriggered: root.statusMessage = ""
  }

  // Tooltip Text
  readonly property string tooltipText: {
    var lines = []
    lines.push("󰻠 CPU: " + root.cpuPercent + "% (" + root.cpuTemp + "°C @ " + (root.cpuAvgFreq > 0 ? (root.cpuAvgFreq / 1000.0).toFixed(1) + "GHz" : "auto") + ")")
    lines.push("󰍛 RAM: " + root.formatKb(root.ramUsedKb) + " / " + root.formatKb(root.ramTotalKb) + " (" + root.ramPercent + "%)" + (root.swapTotalKb > 0 ? " · Swap: " + root.swapPercent + "%" : ""))
    if (root.gpuAvailable) lines.push("󰢮 GPU: " + root.gpuName + " (" + root.gpuPercent + "% · " + root.gpuTemp + "°C)")
    lines.push("󰋊 Disk: " + root.formatBytes(root.diskUsedBytes) + " / " + root.formatBytes(root.diskTotalBytes) + " (" + root.diskPercent + "%)")
    lines.push("󰖩 Net: ↓ " + root.netDownSpeed + " · ↑ " + root.netUpSpeed)
    lines.push("• Click: Dashboard  • Right-Click: btop  • Mid-Click: Trim")
    return lines.join("\n")
  }

  onTooltipTextChanged: {
    if (mouseArea.containsMouse && root.bar) {
      root.bar.showTooltip(root, root.tooltipText)
    }
  }

  // =========================================================================
  // THE BAR WIDGET: Iconic Multi-Meter Tracks with Real-time Glow & Animations
  // =========================================================================
  Item {
    id: barItem
    implicitWidth: barRow.implicitWidth + Style.space(10)
    implicitHeight: root.bar ? root.bar.barSize : 26

    Row {
      id: barRow
      anchors.centerIn: parent
      spacing: Style.space(3)

      Repeater {
        model: root.meters

        Rectangle {
          id: track
          required property var modelData
          readonly property color tint: modelData.hot ? root.urgentColor : root.meterColor

          visible: modelData.shown
          width: Style.space(4)
          height: Style.space(13)
          radius: 1
          color: Qt.rgba(tint.r, tint.g, tint.b, 0.22)

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Math.max(1, Math.round(parent.height * Math.min(100, Math.max(0, track.modelData.value)) / 100.0))
            radius: 1
            color: track.tint

            Behavior on height {
              NumberAnimation { duration: 250; easing.type: Easing.OutQuad }
            }
          }
        }
      }
    }

    MouseArea {
      id: mouseArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) {
          root.openActivity()
        } else if (mouse.button === Qt.MiddleButton) {
          root.cleanCache()
        } else {
          root.toggle()
        }
      }
      onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltipText)
      onExited: if (root.bar) root.bar.hideTooltip(root)
    }
  }

  // =========================================================================
  // THE POPOVER DASHBOARD PANEL (KeyboardPanel)
  // =========================================================================
  KeyboardPanel {
    id: panel
    anchorItem: barItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: mainColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        // ---------------- HEADER ROW ----------------
        Item {
          width: parent.width
          implicitHeight: Math.max(headerLabels.implicitHeight, headerActions.implicitHeight)

          Row {
            id: headerLabels
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              text: "󰍛"
              color: root.accentColor
              font.family: root.barFont
              font.pixelSize: Style.font.title
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              spacing: Style.space(1)
              Text {
                text: "Resources+"
                color: root.barFg
                font.family: root.barFont
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                text: root.systemOverview.hostname + " • " + (root.systemOverview.uptime_str !== "" ? "Up " + root.systemOverview.uptime_str : "Linux " + root.systemOverview.kernel)
                color: Qt.darker(root.barFg, 1.4)
                font.family: root.barFont
                font.pixelSize: Style.font.caption
              }
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              text: "btop"
              iconText: "󰒋"
              fontSize: Style.font.caption
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(4)
              bordered: true
              onClicked: {
                root.close()
                root.openActivity()
              }
            }

            Button {
              text: root.isTrimming ? "Trimming..." : "Trim"
              iconText: "󰐥"
              fontSize: Style.font.caption
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(4)
              bordered: true
              onClicked: root.cleanCache()
            }
          }
        }

        // Status Banner
        Rectangle {
          visible: root.statusMessage !== ""
          width: parent.width
          implicitHeight: statusText.implicitHeight + Style.space(8)
          radius: Style.space(4)
          color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.15)
          border.color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.4)

          Text {
            id: statusText
            anchors.centerIn: parent
            text: root.statusMessage
            color: root.accentColor
            font.family: root.barFont
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        // ---------------- TABS ROW ----------------
        Row {
          width: parent.width
          spacing: Style.space(4)

          Button {
            width: (parent.width - Style.space(12)) / 4
            text: "Overview"
            iconText: "󰻠"
            fontSize: Style.font.caption
            selected: root.currentTab === "overview"
            bordered: true
            onClicked: root.currentTab = "overview"
          }

          Button {
            width: (parent.width - Style.space(12)) / 4
            text: "Processes"
            iconText: "󰘚"
            fontSize: Style.font.caption
            selected: root.currentTab === "procs"
            bordered: true
            onClicked: root.currentTab = "procs"
          }

          Button {
            width: (parent.width - Style.space(12)) / 4
            text: "Sensors"
            iconText: "󰔏"
            fontSize: Style.font.caption
            selected: root.currentTab === "sensors"
            bordered: true
            onClicked: root.currentTab = "sensors"
          }

          Button {
            width: (parent.width - Style.space(12)) / 4
            text: "Disks"
            iconText: "󰋊"
            fontSize: Style.font.caption
            selected: root.currentTab === "disks"
            bordered: true
            onClicked: root.currentTab = "disks"
          }
        }

        PanelSeparator {}

        // =====================================================================
        // TAB 1: OVERVIEW (Hardware Telemetry Grid)
        // =====================================================================
        Column {
          visible: root.currentTab === "overview"
          width: parent.width
          spacing: Style.space(8)

          // --- CPU HERO CARD ---
          Rectangle {
            width: parent.width
            implicitHeight: cpuCol.implicitHeight + Style.space(16)
            radius: Style.space(6)
            color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.04)
            border.color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.1)

            Column {
              id: cpuCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              // Header line
              Item {
                width: parent.width
                implicitHeight: cpuValText.implicitHeight

                Row {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Text {
                    text: "󰻠"
                    color: root.cpuHotStreak >= root.cpuHotSamples ? root.urgentColor : root.accentColor
                    font.family: root.barFont
                    font.pixelSize: Style.font.title
                  }

                  Column {
                    Text {
                      text: "Processor"
                      color: root.barFg
                      font.family: root.barFont
                      font.bold: true
                      font.pixelSize: Style.font.body
                    }
                    Text {
                      text: root.cpuModel
                      color: Qt.darker(root.barFg, 1.4)
                      font.family: root.barFont
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      width: Style.space(220)
                    }
                  }
                }

                Row {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Text {
                    text: root.cpuTemp + "°C"
                    color: root.cpuTemp >= 80 ? root.urgentColor : Qt.darker(root.barFg, 1.2)
                    font.family: root.barFont
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    id: cpuValText
                    text: root.cpuPercent + "%"
                    color: root.cpuHotStreak >= root.cpuHotSamples ? root.urgentColor : root.accentColor
                    font.family: root.barFont
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }
                }
              }

              // Overall CPU Progress Bar
              Rectangle {
                width: parent.width
                height: Style.space(6)
                radius: Style.space(3)
                color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.12)

                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: Math.max(parent.height, parent.width * (root.cpuPercent / 100.0))
                  radius: Style.space(3)
                  color: root.cpuHotStreak >= root.cpuHotSamples ? root.urgentColor : root.accentColor
                }
              }

              // Per-Core Visualization (12 Threads Horizontal Strip)
              Column {
                width: parent.width
                spacing: Style.space(3)
                visible: root.corePercents.length > 0

                Row {
                  width: parent.width
                  spacing: Style.space(2)

                  Repeater {
                    model: root.corePercents

                    Rectangle {
                      required property var modelData
                      required property int index
                      width: (parent.width - Style.space(2) * (root.corePercents.length - 1)) / root.corePercents.length
                      height: Style.space(18)
                      radius: 1
                      color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.1)

                      Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: Math.max(1, Math.round(parent.height * (parent.modelData.percent / 100.0)))
                        radius: 1
                        color: parent.modelData.percent >= 85 ? root.urgentColor : (parent.modelData.percent >= 50 ? Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.85) : root.accentColor)
                      }
                    }
                  }
                }

                Row {
                  width: parent.width
                  Item {
                    width: parent.width / 2
                    Text {
                      text: (root.cpuAvgFreq > 0 ? (root.cpuAvgFreq / 1000.0).toFixed(2) + " GHz" : "Dynamic Freq") + " • " + root.corePercents.length + " Threads"
                      color: Qt.darker(root.barFg, 1.4)
                      font.family: root.barFont
                      font.pixelSize: Style.font.caption
                    }
                  }
                  Item {
                    width: parent.width / 2
                    Text {
                      anchors.right: parent.right
                      text: "Per-core load"
                      color: Qt.darker(root.barFg, 1.6)
                      font.family: root.barFont
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }
          }

          // --- MEMORY & SWAP CARD ---
          Rectangle {
            width: parent.width
            implicitHeight: memCol.implicitHeight + Style.space(16)
            radius: Style.space(6)
            color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.04)
            border.color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.1)

            Column {
              id: memCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              Item {
                width: parent.width
                implicitHeight: memValText.implicitHeight

                Row {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Text {
                    text: "󰍛"
                    color: root.ramPercent >= root.ramHotAt ? root.urgentColor : root.accentColor
                    font.family: root.barFont
                    font.pixelSize: Style.font.title
                  }

                  Column {
                    Text {
                      text: "Memory & Cache"
                      color: root.barFg
                      font.family: root.barFont
                      font.bold: true
                      font.pixelSize: Style.font.body
                    }
                    Text {
                      text: root.formatKb(root.ramUsedKb) + " used / " + root.formatKb(root.ramTotalKb) + " total"
                      color: Qt.darker(root.barFg, 1.4)
                      font.family: root.barFont
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                Text {
                  id: memValText
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.ramPercent + "%"
                  color: root.ramPercent >= root.ramHotAt ? root.urgentColor : root.accentColor
                  font.family: root.barFont
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
              }

              // Segmented RAM Bar
              Rectangle {
                width: parent.width
                height: Style.space(6)
                radius: Style.space(3)
                color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.12)

                // Cache layer
                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: Math.min(parent.width, parent.width * ((root.ramUsedKb + root.cachedKb) / root.ramTotalKb))
                  radius: Style.space(3)
                  color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.35)
                }

                // Active Used layer
                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: Math.max(parent.height, parent.width * (root.ramUsedKb / root.ramTotalKb))
                  radius: Style.space(3)
                  color: root.ramPercent >= root.ramHotAt ? root.urgentColor : root.accentColor
                }
              }

              // Swap Line
              Item {
                width: parent.width
                implicitHeight: swapText.implicitHeight
                visible: root.swapTotalKb > 0

                Text {
                  id: swapText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Swap / ZRAM: " + root.formatKb(root.swapUsedKb) + " / " + root.formatKb(root.swapTotalKb) + " (" + root.swapPercent + "%)"
                  color: Qt.darker(root.barFg, 1.4)
                  font.family: root.barFont
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Cache: " + root.formatKb(root.cachedKb) + " • Free: " + root.formatKb(root.ramAvailKb)
                  color: Qt.darker(root.barFg, 1.5)
                  font.family: root.barFont
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // --- GPU TELEMETRY CARD ---
          Rectangle {
            visible: root.gpuAvailable
            width: parent.width
            implicitHeight: gpuCol.implicitHeight + Style.space(16)
            radius: Style.space(6)
            color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.04)
            border.color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.1)

            Column {
              id: gpuCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              Repeater {
                model: root.gpuList

                Column {
                  id: gpuItemCol
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(4)

                  Item {
                    width: parent.width
                    implicitHeight: gpuLineText.implicitHeight

                    Row {
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(6)

                      Text {
                        text: "󰢮"
                        color: root.accentColor
                        font.family: root.barFont
                        font.pixelSize: Style.font.body
                      }

                      Text {
                        text: gpuItemCol.modelData.name
                        color: root.barFg
                        font.family: root.barFont
                        font.bold: true
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        visible: gpuItemCol.modelData.temp_c > 0
                        text: gpuItemCol.modelData.temp_c + "°C"
                        color: Qt.darker(root.barFg, 1.3)
                        font.family: root.barFont
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Text {
                      id: gpuLineText
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      text: (gpuItemCol.modelData.vram_total_mb > 0 ? gpuItemCol.modelData.vram_used_mb + "/" + gpuItemCol.modelData.vram_total_mb + "MB • " : "") + gpuItemCol.modelData.util_percent + "%"
                      color: gpuItemCol.modelData.util_percent >= root.gpuHotAt ? root.urgentColor : root.accentColor
                      font.family: root.barFont
                      font.bold: true
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Rectangle {
                    width: parent.width
                    height: Style.space(4)
                    radius: Style.space(2)
                    color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.12)

                    Rectangle {
                      anchors.left: parent.left
                      anchors.top: parent.top
                      anchors.bottom: parent.bottom
                      width: Math.max(parent.height, parent.width * (gpuItemCol.modelData.util_percent / 100.0))
                      radius: Style.space(2)
                      color: gpuItemCol.modelData.util_percent >= root.gpuHotAt ? root.urgentColor : root.accentColor
                    }
                  }
                }
              }
            }
          }

          // --- NETWORK & DISK DUAL CARDS ---
          Row {
            width: parent.width
            spacing: Style.space(8)

            // Network Card
            Rectangle {
              width: (parent.width - Style.space(8)) / 2
              implicitHeight: netCol.implicitHeight + Style.space(16)
              radius: Style.space(6)
              color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.04)
              border.color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.1)

              Column {
                id: netCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(10)
                spacing: Style.space(4)

                Row {
                  spacing: Style.space(6)
                  Text {
                    text: "󰖩"
                    color: root.accentColor
                    font.family: root.barFont
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    text: "Network Activity"
                    color: root.barFg
                    font.family: root.barFont
                    font.bold: true
                    font.pixelSize: Style.font.caption
                  }
                }

                Row {
                  spacing: Style.space(6)
                  Text {
                    text: "↓"
                    color: root.accentColor
                    font.family: root.barFont
                    font.bold: true
                  }
                  Text {
                    text: root.netDownSpeed
                    color: root.barFg
                    font.family: root.barFont
                    font.pixelSize: Style.font.caption
                  }
                }

                Row {
                  spacing: Style.space(6)
                  Text {
                    text: "↑"
                    color: Qt.darker(root.barFg, 1.4)
                    font.family: root.barFont
                    font.bold: true
                  }
                  Text {
                    text: root.netUpSpeed
                    color: Qt.darker(root.barFg, 1.3)
                    font.family: root.barFont
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            // Storage I/O Card
            Rectangle {
              width: (parent.width - Style.space(8)) / 2
              implicitHeight: diskCol.implicitHeight + Style.space(16)
              radius: Style.space(6)
              color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.04)
              border.color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.1)

              Column {
                id: diskCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(10)
                spacing: Style.space(4)

                Row {
                  spacing: Style.space(6)
                  Text {
                    text: "󰋊"
                    color: root.diskPercent >= root.diskHotAt ? root.urgentColor : root.accentColor
                    font.family: root.barFont
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    text: "Storage (/)"
                    color: root.barFg
                    font.family: root.barFont
                    font.bold: true
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    text: root.diskPercent + "%"
                    color: root.diskPercent >= root.diskHotAt ? root.urgentColor : root.accentColor
                    font.family: root.barFont
                    font.bold: true
                    font.pixelSize: Style.font.caption
                  }
                }

                Row {
                  spacing: Style.space(6)
                  Text {
                    text: "R: " + root.diskReadSpeed
                    color: root.barFg
                    font.family: root.barFont
                    font.pixelSize: Style.font.caption
                  }
                }

                Row {
                  spacing: Style.space(6)
                  Text {
                    text: "W: " + root.diskWriteSpeed
                    color: Qt.darker(root.barFg, 1.3)
                    font.family: root.barFont
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }

        // =====================================================================
        // TAB 2: PROCESSES (Live Task Manager & Process Killer)
        // =====================================================================
        Column {
          visible: root.currentTab === "procs"
          width: parent.width
          spacing: Style.space(8)

          // Filter buttons and Search bar
          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              text: "🔥 CPU"
              fontSize: Style.font.caption
              selected: root.procFilter === "cpu"
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              bordered: true
              onClicked: root.procFilter = "cpu"
            }

            Button {
              text: "󰍛 RAM"
              fontSize: Style.font.caption
              selected: root.procFilter === "mem"
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              bordered: true
              onClicked: root.procFilter = "mem"
            }

            Button {
              text: "🪟 Windows"
              fontSize: Style.font.caption
              selected: root.procFilter === "win"
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              bordered: true
              onClicked: root.procFilter = "win"
            }

            // Search box
            Rectangle {
              width: parent.width - (Style.space(8) * 3 + Style.space(60) * 3)
              height: Style.space(26)
              radius: Style.space(4)
              color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.08)
              border.color: searchInput.activeFocus ? root.accentColor : Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.15)

              TextInput {
                id: searchInput
                anchors.left: parent.left
                anchors.right: clearSearchBtn.left
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                color: root.barFg
                font.family: root.barFont
                font.pixelSize: Style.font.caption
                clip: true
                text: root.searchQuery
                onTextChanged: root.searchQuery = text

                Text {
                  visible: parent.text === ""
                  text: "Search..."
                  color: Qt.darker(root.barFg, 1.8)
                  font.family: root.barFont
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Text {
                id: clearSearchBtn
                visible: root.searchQuery !== ""
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: "✕"
                color: Qt.darker(root.barFg, 1.4)
                font.family: root.barFont
                font.pixelSize: Style.font.caption
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    searchInput.text = ""
                    root.searchQuery = ""
                  }
                }
              }
            }
          }

          // Process List View
          ListView {
            id: procListView
            width: parent.width
            height: Math.min(contentHeight, Style.space(270))
            spacing: Style.space(4)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            model: root.getDisplayProcesses()

            delegate: Item {
              id: procDelegate
              required property var modelData
              required property int index
              readonly property bool isDying: Boolean(modelData && root.killingPid === modelData.pid)

              width: ListView.view.width
              implicitHeight: Style.space(38)

              Rectangle {
                anchors.fill: parent
                radius: Style.space(4)
                color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, rowMouse.containsMouse ? 0.08 : 0.03)
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
              }

              // Left: Icon + Name + Window info
              Row {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.right: badgesRow.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: (modelData && modelData.is_window) ? "🪟" : "󰒓"
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                  spacing: 1
                  anchors.verticalCenter: parent.verticalCenter
                  Text {
                    text: modelData.name || modelData.comm
                    color: (modelData && modelData.is_window) ? root.accentColor : root.barFg
                    font.family: root.barFont
                    font.bold: true
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: Style.space(160)
                  }
                  Text {
                    text: "PID " + modelData.pid + (modelData.win_title ? " • " + modelData.win_title : "")
                    color: Qt.darker(root.barFg, 1.5)
                    font.family: root.barFont
                    font.pixelSize: Style.font.caption - 1
                    elide: Text.ElideRight
                    width: Style.space(160)
                  }
                }
              }

              // Right: CPU badge + Memory badge + End Task button
              Row {
                id: badgesRow
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                // CPU Badge
                Rectangle {
                  height: Style.space(20)
                  width: cpuBadgeText.implicitWidth + Style.space(8)
                  radius: Style.space(3)
                  color: modelData.cpu_pct >= 20 ? Qt.rgba(root.urgentColor.r, root.urgentColor.g, root.urgentColor.b, 0.25) : Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.08)

                  Text {
                    id: cpuBadgeText
                    anchors.centerIn: parent
                    text: modelData.cpu_pct.toFixed(1) + "%"
                    color: modelData.cpu_pct >= 20 ? root.urgentColor : root.barFg
                    font.family: root.barFont
                    font.pixelSize: Style.font.caption - 1
                    font.bold: true
                  }
                }

                // RAM Badge
                Rectangle {
                  height: Style.space(20)
                  width: memBadgeText.implicitWidth + Style.space(8)
                  radius: Style.space(3)
                  color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.08)

                  Text {
                    id: memBadgeText
                    anchors.centerIn: parent
                    text: root.formatKb(modelData.rss_kb)
                    color: root.barFg
                    font.family: root.barFont
                    font.pixelSize: Style.font.caption - 1
                  }
                }

                // Kill Button
                Rectangle {
                  id: killBtn
                  height: Style.space(22)
                  width: Style.space(22)
                  radius: Style.space(3)
                  color: killMouse.containsMouse ? Qt.rgba(root.urgentColor.r, root.urgentColor.g, root.urgentColor.b, 0.3) : Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.08)
                  border.color: killMouse.containsMouse ? root.urgentColor : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: isDying ? "…" : "✕"
                    color: killMouse.containsMouse ? root.urgentColor : Qt.darker(root.barFg, 1.4)
                    font.bold: true
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    id: killMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.killProcess(modelData.pid, modelData.name)
                  }
                }
              }
            }
          }
        }

        // =====================================================================
        // TAB 3: SENSORS & HARDWARE HEALTH
        // =====================================================================
        Column {
          visible: root.currentTab === "sensors"
          width: parent.width
          spacing: Style.space(8)

          // Temperatures Grid
          Rectangle {
            width: parent.width
            implicitHeight: tempCol.implicitHeight + Style.space(16)
            radius: Style.space(6)
            color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.04)
            border.color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.1)

            Column {
              id: tempCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              spacing: Style.space(6)

              Row {
                spacing: Style.space(6)
                Text {
                  text: "󰔏"
                  color: root.accentColor
                  font.family: root.barFont
                  font.pixelSize: Style.font.body
                }
                Text {
                  text: "Thermal Sensors"
                  color: root.barFg
                  font.family: root.barFont
                  font.bold: true
                  font.pixelSize: Style.font.caption
                }
              }

              Repeater {
                model: root.sensorTemps

                Item {
                  required property var modelData
                  width: parent.width
                  implicitHeight: Style.space(20)

                  Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(6)

                    Text {
                      text: "• " + modelData.name + " (" + modelData.label + ")"
                      color: root.barFg
                      font.family: root.barFont
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.temp_c + " °C"
                    color: modelData.temp_c >= 80 ? root.urgentColor : (modelData.temp_c >= 65 ? root.accentColor : Qt.darker(root.barFg, 1.2))
                    font.family: root.barFont
                    font.bold: true
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          // Fan Speeds Card
          Rectangle {
            visible: root.sensorFans.length > 0
            width: parent.width
            implicitHeight: fanCol.implicitHeight + Style.space(16)
            radius: Style.space(6)
            color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.04)
            border.color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.1)

            Column {
              id: fanCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              spacing: Style.space(6)

              Row {
                spacing: Style.space(6)
                Text {
                  text: "󰈐"
                  color: root.accentColor
                  font.family: root.barFont
                  font.pixelSize: Style.font.body
                }
                Text {
                  text: "Active Cooling Fans"
                  color: root.barFg
                  font.family: root.barFont
                  font.bold: true
                  font.pixelSize: Style.font.caption
                }
              }

              Repeater {
                model: root.sensorFans

                Item {
                  required property var modelData
                  width: parent.width
                  implicitHeight: Style.space(20)

                  Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(6)

                    Text {
                      text: "󰈐 " + modelData.label
                      color: root.barFg
                      font.family: root.barFont
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.rpm + " RPM"
                    color: modelData.rpm > 3500 ? root.urgentColor : root.accentColor
                    font.family: root.barFont
                    font.bold: true
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }

        // =====================================================================
        // TAB 4: DISKS & FILESYSTEMS
        // =====================================================================
        Column {
          visible: root.currentTab === "disks"
          width: parent.width
          spacing: Style.space(8)

          Rectangle {
            width: parent.width
            implicitHeight: diskMountsCol.implicitHeight + Style.space(16)
            radius: Style.space(6)
            color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.04)
            border.color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.1)

            Column {
              id: diskMountsCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              spacing: Style.space(10)

              Row {
                spacing: Style.space(6)
                Text {
                  text: "󰋊"
                  color: root.accentColor
                  font.family: root.barFont
                  font.pixelSize: Style.font.body
                }
                Text {
                  text: "Mounted Storage Drives"
                  color: root.barFg
                  font.family: root.barFont
                  font.bold: true
                  font.pixelSize: Style.font.caption
                }
              }

              Repeater {
                model: root.mounts

                Column {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(3)

                  Item {
                    width: parent.width
                    implicitHeight: Style.space(16)

                    Text {
                      text: modelData.mount + " (" + modelData.device + " • " + modelData.fstype + ")"
                      color: root.barFg
                      font.family: root.barFont
                      font.bold: true
                      font.pixelSize: Style.font.caption
                      anchors.left: parent.left
                    }

                    Text {
                      text: root.formatBytes(modelData.used_bytes) + " / " + root.formatBytes(modelData.total_bytes) + " (" + modelData.percent + "%)"
                      color: modelData.percent >= root.diskHotAt ? root.urgentColor : root.accentColor
                      font.family: root.barFont
                      font.bold: true
                      font.pixelSize: Style.font.caption
                      anchors.right: parent.right
                    }
                  }

                  Rectangle {
                    width: parent.width
                    height: Style.space(4)
                    radius: Style.space(2)
                    color: Qt.rgba(root.barFg.r, root.barFg.g, root.barFg.b, 0.12)

                    Rectangle {
                      anchors.left: parent.left
                      anchors.top: parent.top
                      anchors.bottom: parent.bottom
                      width: Math.max(parent.height, parent.width * (modelData.percent / 100.0))
                      radius: Style.space(2)
                      color: modelData.percent >= root.diskHotAt ? root.urgentColor : root.accentColor
                    }
                  }
                }
              }
            }
          }
        }

        // ---------------- FOOTER ROW ----------------
        PanelSeparator {}

        Item {
          width: parent.width
          implicitHeight: Style.space(22)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "• Left-Click: Toggle  • Right-Click: btop  • Mid-Click: Trim"
            color: Qt.darker(root.barFg, 1.6)
            font.family: root.barFont
            font.pixelSize: Style.font.caption - 1
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Esc to close"
            color: Qt.darker(root.barFg, 1.8)
            font.family: root.barFont
            font.pixelSize: Style.font.caption - 1
          }
        }
      }
    }
  }
}

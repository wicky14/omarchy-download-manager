import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "omakid.download-manager"

  readonly property var svc: bar ? bar.shell.serviceFor("omakid.download-manager") : null
  readonly property var speedLimits: [0, 131072, 262144, 524288, 1048576, 2097152, 5242880, 10485760]

  property bool popupOpen: false
  property string pickDir: svc && svc.settings ? svc.settings.defaultDir : "~/Downloads"
  property string addMsg: ""
  property int rowHeight: Style.space(58)

  property int uiSlots: svc && svc.settings ? svc.settings.maxConcurrent : 3
  property int uiSegments: svc && svc.settings ? svc.settings.segments : 8
  property int uiSpeedIdx: root.speedIndexFor(svc && svc.settings ? svc.settings.speedLimit : 0)

  function close() { popupOpen = false }

  function summaryText() {
    if (!svc || !svc.ready) return "memuat\u2026"
    if (svc.activeCount > 0) {
      var s = svc.activeCount + " aktif"
      if (svc.queuedCount > 0) s += " +" + svc.queuedCount
      if (svc.totalSpeed > 0) s += " \u00b7 " + Model.formatSpeed(svc.totalSpeed)
      return s
    }
    if (svc.pausedCount > 0) return svc.pausedCount + " dijeda"
    if (svc.completedCount + svc.errorCount + svc.cancelledCount === 0) return "siap"
    return "0 aktif"
  }

  function footerText() {
    if (!svc) return ""
    var parts = []
    if (svc.completedCount > 0) parts.push(svc.completedCount + " selesai")
    if (svc.errorCount > 0) parts.push(svc.errorCount + " gagal")
    if (svc.cancelledCount > 0) parts.push(svc.cancelledCount + " batal")
    return parts.join(" \u00b7 ")
  }

  function speedIndexFor(v) {
    var n = Number(v)
    for (var i = 0; i < root.speedLimits.length; i++) {
      if (root.speedLimits[i] === n) return i
    }
    return 0
  }

  function addCurrent() {
    var u = urlField.text.trim()
    if (!Model.isValidUrl(u)) {
      root.addMsg = "URL tidak valid."
      return
    }
    var ok = svc ? svc.addUrl(u, root.pickDir) : false
    if (ok) {
      urlField.text = ""
      root.addMsg = "Ditambahkan ke antrean."
      addMsgTimer.restart()
    } else {
      root.addMsg = "URL sudah ada di daftar."
    }
  }

  function chooseDir() {
    pickProc.command = ["bash", root.folderHelper]
    pickProc.running = true
  }

  function toggleAll() {
    if (svc) svc.toggleAll()
  }

  readonly property string folderHelper: decodeURIComponent(
    Qt.resolvedUrl("folderpick.sh").toString().replace(/^file:\/\//, ""))

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf019" + ((svc && svc.activeCount > 0) ? " " + svc.activeCount : "")
    fontSize: Style.font.caption
    tooltipText: "Download Manager\nKlik kiri: panel\nKlik kanan: jeda/lanjut semua"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.popupOpen = !root.popupOpen
      else if (buttonCode === Qt.RightButton) root.toggleAll()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.popupOpen
    focusTarget: urlField
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(600))

    Item {
      anchors.fill: parent

      Column {
        id: content
        anchors.fill: parent
        spacing: 0

        // ---------- clipboard suggestion ----------
        Item {
          width: parent.width
          visible: svc && svc.pendingClipboard.length > 0
          height: svc && svc.pendingClipboard.length > 0
            ? clipCol.implicitHeight + Style.space(10)
            : 0
          clip: true

          Column {
            id: clipCol
            width: parent.width
            spacing: 0

            Item {
              width: parent.width
              height: Style.space(30)

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "URL DARI KLIPBOARD"
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Repeater {
              model: svc && svc.pendingClipboard ? svc.pendingClipboard : []

              Row {
                required property var modelData
                width: clipCol.width
                height: Style.space(26)

                Text {
                  width: parent.width - Style.space(100)
                  textFormat: Text.PlainText
                  text: modelData.url
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                  anchors.verticalCenter: parent.verticalCenter
                }

                Button {
                  width: Style.space(48)
                  height: Style.space(24)
                  iconText: "\uf067"
                  text: "Tambah"
                  foreground: root.bar.foreground
                  verticalPadding: 0
                  horizontalPadding: 0
                  onClicked: { if (svc) svc.applyClipboard(modelData.url) }
                }

                Button {
                  width: Style.space(28)
                  height: Style.space(24)
                  iconText: "\uf00d"
                  foreground: Qt.darker(root.bar.foreground, 1.3)
                  verticalPadding: 0
                  horizontalPadding: 0
                  onClicked: { if (svc) svc.dismissClipboard(modelData.url) }
                }
              }
            }

            PanelSeparator { foreground: root.bar.foreground }
          }
        }

        // ---------- header ----------
        Item {
          width: parent.width
          height: Style.space(36)

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "DOWNLOAD MANAGER"
            color: Qt.darker(root.bar.foreground, 1.2)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.summaryText()
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- add form ----------
        Item {
          width: parent.width
          height: formCol.implicitHeight + Style.space(14)

          Column {
            id: formCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: urlField
                width: parent.width - addButton.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                placeholderText: "Tempel URL direct\u2026"
                maximumLength: 2048
                onAccepted: root.addCurrent()
              }

              Button {
                id: addButton
                iconText: "\uf067"
                text: "Tambah"
                foreground: root.bar.foreground
                bordered: true
                implicitWidth: Style.space(88)
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.addCurrent()
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: Style.space(34)
                height: Style.space(26)
                iconText: "\uf07c"
                foreground: root.bar.foreground
                verticalPadding: 0
                horizontalPadding: 0
                onClicked: root.chooseDir()
              }

              Text {
                width: parent.width - Style.space(42)
                textFormat: Text.PlainText
                text: root.pickDir
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.addMsg
              visible: root.addMsg !== ""
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              visible: svc ? svc.aria2Missing : false
              text: "aria2 belum terpasang \u2014 jalankan: omarchy pkg add aria2"
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- options sliders ----------
        Item {
          width: parent.width
          height: Style.space(64)

          Row {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(14)

            Column {
              width: (parent.width - parent.spacing * 2) / 3
              spacing: Style.space(2)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "SLOT: " + root.uiSlots
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
              }

              Item {
                width: parent.width
                height: Style.space(24)

                PanelSlider {
                  bar: root.bar
                  anchors.fill: parent
                  minimum: 1
                  maximum: 16
                  step: 1
                  integer: true
                  value: root.uiSlots
                  onMoved: function(v) { root.uiSlots = v }
                  onReleased: function(v) { root.uiSlots = v; if (svc) svc.setMaxConcurrent(v) }
                }
              }
            }

            Column {
              width: (parent.width - parent.spacing * 2) / 3
              spacing: Style.space(2)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "SEGMEN: " + root.uiSegments
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
              }

              Item {
                width: parent.width
                height: Style.space(24)

                PanelSlider {
                  bar: root.bar
                  anchors.fill: parent
                  minimum: 1
                  maximum: 16
                  step: 1
                  integer: true
                  value: root.uiSegments
                  onMoved: function(v) { root.uiSegments = v }
                  onReleased: function(v) { root.uiSegments = v; if (svc) svc.setSegments(v) }
                }
              }
            }

            Column {
              width: (parent.width - parent.spacing * 2) / 3
              spacing: Style.space(2)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "BATAS KECEPATAN"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.speedLimits[root.uiSpeedIdx] <= 0
                  ? "Tanpa batas"
                  : Model.formatSpeed(root.speedLimits[root.uiSpeedIdx])
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
              }

              Item {
                width: parent.width
                height: Style.space(24)

                PanelSlider {
                  bar: root.bar
                  anchors.fill: parent
                  minimum: 0
                  maximum: root.speedLimits.length - 1
                  step: 1
                  integer: true
                  value: root.uiSpeedIdx
                  onMoved: function(v) { root.uiSpeedIdx = v }
                  onReleased: function(v) { root.uiSpeedIdx = v; if (svc) svc.setSpeedLimit(root.speedLimits[v]) }
                }
              }
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- list header ----------
        Item {
          width: parent.width
          height: Style.space(30)

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "AKTIVITAS (" + (svc ? svc.downloads.length : 0) + ")"
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- download list ----------
        Item {
          width: parent.width
          height: (svc && svc.downloads.length > 0)
            ? Math.min(svc.downloads.length * root.rowHeight, Style.space(300))
            : Style.space(64)

          Flickable {
            id: listScroll
            anchors.fill: parent
            clip: true
            contentHeight: scrollContent.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar {
              policy: listScroll.contentHeight > listScroll.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
            }

            Column {
              id: scrollContent
              width: parent.width
              spacing: 0

              Repeater {
                model: svc ? svc.downloads : []

                BorderSurface {
                  required property var modelData
                  required property int index
                  width: scrollContent.width
                  height: root.rowHeight
                  radius: 0
                  color: rowHover.containsMouse
                    ? Style.hoverFillFor(root.bar.foreground, root.bar.foreground)
                    : "transparent"
                  borderSpec: Border.none()

                  QtObject {
                    id: rowCtx
                    property var st: svc ? (svc.statuses[modelData.id] || null) : null
                  }

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    spacing: Style.space(8)

                    Text {
                      width: Style.space(20)
                      textFormat: Text.PlainText
                      text: Model.statusIcon(modelData.state)
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.subtitle
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                      width: parent.width - Style.space(20) - (rowActions.implicitWidth + parent.spacing)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(3)

                      Row {
                        width: parent.width
                        spacing: Style.space(6)

                        Text {
                          width: parent.width - pctLabel.width - parent.spacing
                          textFormat: Text.PlainText
                          text: modelData.filename
                          color: root.bar.foreground
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          elide: Text.ElideRight
                        }

                        Text {
                          id: pctLabel
                          textFormat: Text.PlainText
                          text: {
                            var p = rowCtx.st ? Model.percent(rowCtx.st.completed, rowCtx.st.total) : -1
                            return p >= 0 ? p + "%" : (modelData.state === "completed" ? "100%" : "")
                          }
                          color: Qt.darker(root.bar.foreground, 1.4)
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }
                      }

                      Item {
                        width: parent.width
                        height: Style.space(4)

                        Rectangle {
                          anchors.fill: parent
                          radius: Style.space(2)
                          color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.15)
                        }

                        Rectangle {
                          height: parent.height
                          radius: Style.space(2)
                          color: root.bar.foreground
                          width: {
                            var p = rowCtx.st ? Model.percent(rowCtx.st.completed, rowCtx.st.total) : -1
                            if (p < 0) {
                              if (modelData.state === "active" || modelData.state === "paused") return Style.space(6)
                              if (modelData.state === "completed") return parent.width
                              return 0
                            }
                            if (p >= 100) return parent.width
                            return Math.max(Style.space(6), parent.width * p / 100)
                          }
                        }
                      }

                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: Model.describe(modelData, rowCtx.st)
                        color: Qt.darker(root.bar.foreground, 1.4)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                        maximumLineCount: 1
                      }
                    }

                    Row {
                      id: rowActions
                      spacing: Style.space(2)
                      anchors.verticalCenter: parent.verticalCenter

                      Button {
                        width: Style.space(26)
                        height: Style.space(26)
                        iconText: "\uf04c"
                        visible: modelData.state === "active"
                        foreground: root.bar.foreground
                        verticalPadding: 0
                        horizontalPadding: 0
                        onClicked: { if (svc) svc.pause(modelData.id) }
                      }

                      Button {
                        width: Style.space(26)
                        height: Style.space(26)
                        iconText: "\uf04b"
                        visible: modelData.state === "paused"
                        foreground: root.bar.foreground
                        verticalPadding: 0
                        horizontalPadding: 0
                        onClicked: { if (svc) svc.resume(modelData.id) }
                      }

                      Button {
                        width: Style.space(26)
                        height: Style.space(26)
                        iconText: "\uf01e"
                        visible: modelData.state === "error" || modelData.state === "cancelled"
                        foreground: root.bar.foreground
                        verticalPadding: 0
                        horizontalPadding: 0
                        onClicked: { if (svc) svc.retry(modelData.id) }
                      }

                      Button {
                        width: Style.space(26)
                        height: Style.space(26)
                        iconText: "\uf07c"
                        visible: modelData.state === "completed"
                        foreground: root.bar.foreground
                        verticalPadding: 0
                        horizontalPadding: 0
                        onClicked: { if (svc) svc.open(modelData.id) }
                      }

                      Button {
                        width: Style.space(26)
                        height: Style.space(26)
                        iconText: modelData.state === "completed" ? "\uf2ed" : "\uf00d"
                        foreground: Qt.darker(root.bar.foreground, 1.3)
                        verticalPadding: 0
                        horizontalPadding: 0
                        onClicked: {
                          if (!svc) return
                          if (Model.isFinal(modelData.state)) svc.removeEntry(modelData.id)
                          else svc.cancel(modelData.id)
                        }
                      }
                    }
                  }

                  MouseArea {
                    id: rowHover
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: { if (modelData.state === "completed" && svc) svc.open(modelData.id) }
                  }
                }
              }

              Item {
                width: parent.width
                height: visible ? Style.space(64) : 0
                visible: svc ? svc.downloads.length === 0 : true

                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: "Belum ada download \u2014 tempel URL di atas untuk mulai."
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- footer ----------
        Item {
          width: parent.width
          height: Style.space(38)

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.footerText()
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Button {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\uf2ed"
            text: "Bersihkan"
            foreground: svc && (svc.completedCount + svc.errorCount + svc.cancelledCount > 0)
              ? root.bar.foreground
              : Qt.darker(root.bar.foreground, 1.7)
            bordered: true
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            enabled: svc && (svc.completedCount + svc.errorCount + svc.cancelledCount > 0)
            onClicked: { if (svc) svc.clearFinished() }
          }
        }
      }
    }
  }

  Timer {
    id: addMsgTimer
    interval: 3000
    repeat: false
    onTriggered: root.addMsg = ""
  }

  Process {
    id: pickProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = String(text || "").trim()
        if (d) root.pickDir = d
      }
    }
  }

  Component.onCompleted: {
    if (svc && svc.settings) root.pickDir = svc.settings.defaultDir
  }
}
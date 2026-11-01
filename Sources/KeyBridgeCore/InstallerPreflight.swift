// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// Executes only the installer's advertised-product/component queries in a
/// disposable copy of the bundled Alpine. No working generation, USB device,
/// network interface, or host port is used by this check.
public enum InstallerPreflight {
    public static func inspect(_ installer: URL, resources: URL, workspace: URL,
                               cancelled: @escaping () -> Bool = { false }) throws -> [String: Any] {
        let fm = FileManager.default
        func checkCancellation() throws {
            if cancelled() { throw BridgeError("Проверка файла отменена.") }
        }
        try checkCancellation()
        try BridgePaths.preparePrivateDirectory(workspace)
        let run = workspace.appendingPathComponent("preflight-" + UUID().uuidString)
        try BridgePaths.preparePrivateDirectory(run)
        defer { try? fm.removeItem(at: run) }
        let base = resources.appendingPathComponent("base")
        let qemu = resources.appendingPathComponent("runtime/bin/qemu-system-x86_64")
        let imageTool = resources.appendingPathComponent("runtime/bin/qemu-img")
        let policy = resources.appendingPathComponent("guest/verify_imports.sh")
        for file in [qemu, imageTool, policy, base.appendingPathComponent("alpine.qcow2"),
                     base.appendingPathComponent("vmlinuz-virt"), base.appendingPathComponent("initramfs-virt")] {
            guard fm.fileExists(atPath: file.path) else {
                throw BridgeError("Не найден компонент проверки установщика. Установите полную сборку KeyBridge и выберите файл снова.")
            }
        }
        let size = try installer.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        // The ISO temporarily duplicates the input; the overlay holds swap and
        // modest filesystem writes. The source and working VM remain untouched.
        guard try RuntimeResources.availableBytes(run) >= Int64(size) + 768 * 1024 * 1024 else {
            throw BridgeError("Не хватает места для проверки установщика. Освободите место на Mac и выберите файл снова.")
        }
        func command(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws {
            let result = try hostCommand(executable, arguments, timeout: timeout, isCancelled: cancelled)
            try checkCancellation()
            guard result.code == 0, !result.timedOut else {
                throw BridgeError("Не удалось подготовить проверку установщика. Выберите файл снова; если ошибка повторится, переустановите KeyBridge.")
            }
        }
        let imports = run.appendingPathComponent("imports")
        try BridgePaths.preparePrivateDirectory(imports)
        let setup = imports.appendingPathComponent("setup.run")
        // A copy-on-write clone avoids a third physical input copy on APFS and
        // lets us set execute permission without changing the selected file.
        if clonefile(installer.path, setup.path, 0) != 0 {
            guard try RuntimeResources.availableBytes(run) >= Int64(size) * 2 + 768 * 1024 * 1024 else {
                throw BridgeError("Не хватает места для временных копий установщика. Освободите место на Mac и выберите файл снова.")
            }
            try fm.copyItem(at: installer, to: setup)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: setup.path)
        try fm.copyItem(at: policy, to: imports.appendingPathComponent("verify_imports.sh"))
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let script = """
        #!/bin/sh
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
        cd /mnt/check || exit 1
        swap=/var/lib/keybridge/preflight.swap
        mkdir -p /var/lib/keybridge
        result=1
        if dd if=/dev/zero of="$swap" bs=1M count=512 2>/dev/null && chmod 600 "$swap" && mkswap "$swap" >/dev/null && swapon "$swap"; then
          sh ./verify_imports.sh --installer-only
          result=$?
        fi
        swapoff "$swap" 2>/dev/null || true
        rm -f "$swap"
        printf '\\nKEYBRIDGE_PREFLIGHT_\(token)=%s\\n' "$result"
        sync
        poweroff -f
        """
        try script.write(to: imports.appendingPathComponent("check.sh"), atomically: true, encoding: .utf8)
        let iso = run.appendingPathComponent("imports.iso")
        try command("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-default-volume-name", "keybridge-check",
                                       "-o", iso.path, imports.path], timeout: 300)
        let overlay = run.appendingPathComponent("guest.qcow2")
        try command(imageTool.path, ["create", "-f", "qcow2", "-F", "qcow2", "-b", base.appendingPathComponent("alpine.qcow2").path,
                                     overlay.path], timeout: 20)
        try checkCancellation()
        let serial = run.appendingPathComponent("serial.log")
        guard fm.createFile(atPath: serial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BridgeError("Не удалось создать временный файл проверки. Освободите место на Mac и повторите выбор.")
        }
        let output = try FileHandle(forWritingTo: serial)
        let reader = try FileHandle(forReadingFrom: serial)
        defer { try? output.close(); try? reader.close() }
        let input = Pipe()
        let process = Process()
        process.executableURL = qemu
        func escaped(_ path: URL) -> String { path.path.replacingOccurrences(of: ",", with: ",,") }
        process.arguments = ["-name", "keybridge-file-check-" + token,
                             "-L", resources.appendingPathComponent("runtime/share/qemu").path,
                             "-machine", "q35", "-accel", "tcg,thread=single,tb-size=16", "-cpu", "max", "-smp", "1", "-m", "128",
                             "-nodefaults", "-display", "none", "-monitor", "none", "-serial", "stdio", "-nic", "none", "-no-reboot",
                             "-drive", "file=\(escaped(overlay)),if=virtio,format=qcow2,discard=unmap",
                             "-drive", "file=\(escaped(iso)),if=ide,media=cdrom,readonly=on",
                             "-kernel", base.appendingPathComponent("vmlinuz-virt").path,
                             "-initrd", base.appendingPathComponent("initramfs-virt").path,
                             "-append", "root=/dev/vda rootfstype=ext4 rw console=ttyS0 modules=virtio_pci,virtio_blk,ext4 init=/bin/sh"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                let until = Date().addingTimeInterval(1)
                while process.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? input.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(780)
        let bootDeadline = Date().addingTimeInterval(150)
        var started = false, tail = Data()
        func readOutput() throws -> String {
            // Keep the spool bounded even if a malformed file is excessively noisy.
            guard (try serial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 4 * 1024 * 1024 else {
                throw BridgeError("Установщик вернул слишком большой ответ. Выберите другой дистрибутив 1С.")
            }
            while let bytes = try reader.read(upToCount: 64 * 1024), !bytes.isEmpty {
                tail.append(bytes)
                if tail.count > 256 * 1024 { tail.removeFirst(tail.count - 256 * 1024) }
            }
            return String(decoding: tail, as: UTF8.self)
        }
        var transcript = ""
        defer { try? transcript.write(to: workspace.appendingPathComponent("preflight.log"), atomically: true, encoding: .utf8) }
        while process.isRunning {
            try checkCancellation()
            transcript = try readOutput()
            if !started, transcript.contains("/ #") || transcript.contains("/bin/sh: can't access tty") {
                let boot = "mount -t proc proc /proc; mount -t sysfs sys /sys; mount -o remount,rw / && mkdir -p /mnt/check && mount -t iso9660 -o ro /dev/sr0 /mnt/check && sh /mnt/check/check.sh || poweroff -f\n"
                try input.fileHandleForWriting.write(contentsOf: Data(boot.utf8))
                started = true
            }
            if (!started && Date() > bootDeadline) || Date() > deadline {
                throw BridgeError("Проверка установщика не завершилась вовремя. Выберите файл снова; если ошибка повторится, скачайте другой дистрибутив 1С.")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        transcript = try readOutput()
        try checkCancellation()
        if transcript.contains("KEYBRIDGE_ERROR=missing_license_manager") {
            throw BridgeError("В выбранном установщике 1С нет менеджера лицензий. Выберите другой дистрибутив 1С для Linux x86-64 с этим компонентом.")
        }
        if transcript.contains("KEYBRIDGE_ERROR=invalid_platform_installer") {
            throw BridgeError("Файл не подтвердил, что это исправный установщик 1С. Скачайте дистрибутив 1С для Linux x86-64 заново и выберите его.")
        }
        guard process.terminationStatus == 0, transcript.contains("KEYBRIDGE_PREFLIGHT_" + token + "=0"),
              transcript.contains("KEYBRIDGE_IMPORTS_VERIFIED") else {
            throw BridgeError("Не удалось проверить состав установщика. Выберите файл снова; если ошибка повторится, скачайте другой дистрибутив 1С.")
        }
        return ["valid": true, "kind": "installer", "validation": "preflight", "architecture": "x86_64",
                "message": "Установщик 1С содержит в списке компонентов менеджер лицензий."]
    }
}

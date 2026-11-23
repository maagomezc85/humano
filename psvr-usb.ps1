param(
  [ValidateSet("vr-mode", "cinematic-mode", "status")]
  [string]$Action = "vr-mode"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$guidSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

$regPaths = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_054C&PID_09AF&MI_05\*\Device Parameters" -ErrorAction SilentlyContinue
foreach ($item in $regPaths) {
  if ($item.DeviceInterfaceGUIDs) {
    foreach ($g in $item.DeviceInterfaceGUIDs) {
      if ($g) { [void]$guidSet.Add($g.ToString().Trim()) }
    }
  }
  if ($item.DeviceInterfaceGUID) {
    [void]$guidSet.Add($item.DeviceInterfaceGUID.ToString().Trim())
  }
}

[void]$guidSet.Add("{19BC54D7-79B5-6F56-81E6-DAC811AD5EEB}")
[void]$guidSet.Add("{A5DCBF10-6530-11D2-901F-00C04FB951ED}")

$candidateGuids = New-Object string[] $guidSet.Count
$guidSet.CopyTo($candidateGuids)

$cs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class PsvrWinUsbBridge {
    const uint DIGCF_PRESENT = 0x02;
    const uint DIGCF_DEVICEINTERFACE = 0x10;
    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 1;
    const uint FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3;
    const uint FILE_FLAG_OVERLAPPED = 0x40000000;
    const uint PIPE_TRANSFER_TIMEOUT = 0x03;

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SP_DEVICE_INTERFACE_DETAIL_DATA {
        public int cbSize;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 512)]
        public string DevicePath;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct USB_INTERFACE_DESCRIPTOR {
        public byte bLength;
        public byte bDescriptorType;
        public byte bInterfaceNumber;
        public byte bAlternateSetting;
        public byte bNumEndpoints;
        public byte bInterfaceClass;
        public byte bInterfaceSubClass;
        public byte bInterfaceProtocol;
        public byte iInterface;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct WINUSB_PIPE_INFORMATION {
        public int PipeType;
        public byte PipeId;
        public ushort MaximumPacketSize;
        public byte Interval;
    }

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid ClassGuid, IntPtr Enumerator, IntPtr hwndParent, uint Flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr DeviceInfoSet, IntPtr DeviceInfoData, ref Guid InterfaceClassGuid, uint MemberIndex, ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr DeviceInfoSet, ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData, ref SP_DEVICE_INTERFACE_DETAIL_DATA DetailData, int DetailDataSize, out int RequiredSize, IntPtr DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    [DllImport("winusb.dll", SetLastError = true)]
    static extern bool WinUsb_Initialize(IntPtr DeviceHandle, out IntPtr InterfaceHandle);

    [DllImport("winusb.dll", SetLastError = true)]
    static extern bool WinUsb_Free(IntPtr InterfaceHandle);

    [DllImport("winusb.dll", SetLastError = true)]
    static extern bool WinUsb_QueryInterfaceSettings(IntPtr InterfaceHandle, byte AlternateInterfaceNumber, out USB_INTERFACE_DESCRIPTOR UsbAltInterfaceDescriptor);

    [DllImport("winusb.dll", SetLastError = true)]
    static extern bool WinUsb_QueryPipe(IntPtr InterfaceHandle, byte AlternateInterfaceNumber, byte PipeIndex, out WINUSB_PIPE_INFORMATION PipeInformation);

    [DllImport("winusb.dll", SetLastError = true)]
    static extern bool WinUsb_SetPipePolicy(IntPtr InterfaceHandle, byte PipeID, uint PolicyType, uint ValueLength, ref uint Value);

    [DllImport("winusb.dll", SetLastError = true)]
    static extern bool WinUsb_WritePipe(IntPtr InterfaceHandle, byte PipeID, byte[] Buffer, uint BufferLength, out uint LengthTransferred, IntPtr Overlapped);

    static string JsonEscape(string s) {
        if (string.IsNullOrEmpty(s)) return "";
        var sb = new StringBuilder(s.Length + 16);
        foreach (char c in s) {
            switch (c) {
                case '\\': sb.Append("\\\\"); break;
                case '"': sb.Append("\\\""); break;
                case '\r': sb.Append("\\r"); break;
                case '\n': sb.Append("\\n"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < ' ') sb.AppendFormat("\\u{0:X4}", (int)c);
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    static string JsonError(string code, int win32, string error) {
        return string.Format(
            "{{\"ok\":false,\"code\":\"{0}\",\"win32\":{1},\"error\":\"{2}\"}}",
            JsonEscape(code), win32, JsonEscape(error)
        );
    }

    static byte[] MakeReport(byte reportId, byte[] payload) {
        byte[] buf = new byte[64];
        buf[0] = reportId;
        buf[1] = 0x00;
        buf[2] = 0xaa;
        buf[3] = (byte)payload.Length;
        Array.Copy(payload, 0, buf, 4, payload.Length);
        return buf;
    }

    static List<string> FindCandidatePaths(string[] guidStrings) {
        var found = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (string gs in guidStrings) {
            Guid g;
            if (!Guid.TryParse(gs, out g)) continue;
            IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
            if (set == new IntPtr(-1)) continue;
            try {
                uint idx = 0;
                while (true) {
                    var ifData = new SP_DEVICE_INTERFACE_DATA();
                    ifData.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                    if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, idx, ref ifData)) break;
                    idx++;

                    var detail = new SP_DEVICE_INTERFACE_DETAIL_DATA();
                    detail.cbSize = IntPtr.Size == 8 ? 8 : 6;
                    int req;
                    if (!SetupDiGetDeviceInterfaceDetail(set, ref ifData, ref detail, Marshal.SizeOf(detail), out req, IntPtr.Zero)) continue;

                    string p = detail.DevicePath ?? "";
                    string low = p.ToLowerInvariant();
                    if (low.Contains("vid_054c") && low.Contains("pid_09af") && seen.Add(p)) {
                        found.Add(p);
                    }
                }
            } finally {
                SetupDiDestroyDeviceInfoList(set);
            }
        }

        found.Sort((a, b) => {
            bool aMi05 = a.ToLowerInvariant().Contains("mi_05");
            bool bMi05 = b.ToLowerInvariant().Contains("mi_05");
            if (aMi05 != bMi05) return aMi05 ? -1 : 1;
            return string.Compare(a, b, StringComparison.OrdinalIgnoreCase);
        });
        return found;
    }

    public static string Run(string action, string[] guidStrings) {
        try {
            List<string> paths = FindCandidatePaths(guidStrings);
            if (paths.Count == 0) {
                return JsonError(
                    "NOT_FOUND",
                    0,
                    "No se detectó el PSVR por USB (MI_05). Verifica que la caja procesadora esté conectada por USB y encendida."
                );
            }

            string targetPath = paths[0];
            IntPtr fh = CreateFile(
                targetPath,
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                IntPtr.Zero,
                OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED,
                IntPtr.Zero
            );
            if (fh == new IntPtr(-1)) {
                int err = Marshal.GetLastWin32Error();
                if (err == 5 || err == 32) {
                    return JsonError(
                        "BUSY",
                        err,
                        "El control USB del PSVR está ocupado por SteamVR o iVRy. Cierra SteamVR completamente y reintenta."
                    );
                }
                return JsonError("OPEN_FAILED", err, "No se pudo abrir la interfaz WinUSB del PSVR (código Win32 " + err + ").");
            }

            try {
                IntPtr usb;
                if (!WinUsb_Initialize(fh, out usb)) {
                    int err = Marshal.GetLastWin32Error();
                    if (err == 5 || err == 32) {
                        return JsonError(
                            "BUSY",
                            err,
                            "El control USB del PSVR está ocupado por SteamVR o iVRy. Cierra SteamVR completamente y reintenta."
                        );
                    }
                    return JsonError("WINUSB_INIT_FAILED", err, "No se pudo inicializar WinUSB del PSVR (código Win32 " + err + ").");
                }

                try {
                    USB_INTERFACE_DESCRIPTOR desc;
                    if (!WinUsb_QueryInterfaceSettings(usb, 0, out desc)) {
                        int err = Marshal.GetLastWin32Error();
                        return JsonError("QUERY_IFACE_FAILED", err, "No se pudo consultar la interfaz USB del PSVR.");
                    }

                    byte outPipe = 0;
                    bool foundOut = false;
                    for (byte i = 0; i < desc.bNumEndpoints; i++) {
                        WINUSB_PIPE_INFORMATION p;
                        if (WinUsb_QueryPipe(usb, 0, i, out p)) {
                            if ((p.PipeId & 0x80) == 0) {
                                if (!foundOut || p.PipeId == 0x04) {
                                    outPipe = p.PipeId;
                                    foundOut = true;
                                }
                            }
                        }
                    }

                    if (!foundOut) {
                        return JsonError("NO_OUT_PIPE", 0, "No se encontró el canal de salida USB (endpoint OUT) en MI_05.");
                    }

                    uint timeoutMs = 1500;
                    WinUsb_SetPipePolicy(usb, outPipe, PIPE_TRANSFER_TIMEOUT, 4, ref timeoutMs);

                    var writtenCounts = new List<uint>();
                    if (action == "vr-mode") {
                        byte[][] cmds = new byte[][] {
                            MakeReport(0x17, new byte[] { 0x01, 0x00, 0x00, 0x00 }),
                            MakeReport(0x23, new byte[] { 0x01, 0x00, 0x00, 0x00 }),
                            MakeReport(0x11, new byte[] { 0x00, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00 })
                        };
                        int[] delays = new int[] { 220, 150, 0 };
                        for (int i = 0; i < cmds.Length; i++) {
                            uint transferred;
                            if (!WinUsb_WritePipe(usb, outPipe, cmds[i], (uint)cmds[i].Length, out transferred, IntPtr.Zero)) {
                                int err = Marshal.GetLastWin32Error();
                                return JsonError("WRITE_FAILED", err, "Error al enviar comando USB #" + (i + 1) + " al PSVR (Win32 " + err + ").");
                            }
                            writtenCounts.Add(transferred);
                            if (delays[i] > 0) Thread.Sleep(delays[i]);
                        }
                    } else if (action == "cinematic-mode") {
                        byte[] cmd = MakeReport(0x23, new byte[] { 0x00, 0x00, 0x00, 0x00 });
                        uint transferred;
                        if (!WinUsb_WritePipe(usb, outPipe, cmd, (uint)cmd.Length, out transferred, IntPtr.Zero)) {
                            int err = Marshal.GetLastWin32Error();
                            return JsonError("WRITE_FAILED", err, "Error al restaurar modo Cine 2D en el PSVR (Win32 " + err + ").");
                        }
                        writtenCounts.Add(transferred);
                    }

                    return string.Format(
                        "{{\"ok\":true,\"action\":\"{0}\",\"pipe\":\"0x{1:X2}\",\"written\":[{2}],\"path\":\"{3}\"}}",
                        JsonEscape(action),
                        outPipe,
                        string.Join(",", writtenCounts),
                        JsonEscape(targetPath)
                    );
                } finally {
                    WinUsb_Free(usb);
                }
            } finally {
                CloseHandle(fh);
            }
        } catch (Exception ex) {
            return JsonError("EXCEPTION", 0, ex.Message);
        }
    }
}
'@

Add-Type -TypeDefinition $cs
$jsonOut = [PsvrWinUsbBridge]::Run($Action, $candidateGuids)
Write-Output $jsonOut

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'db_workspace_page.dart';
import 'secure_storage.dart';
import 'ssh_workspace_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VpnOpenoiaApp());
}

class VpnOpenoiaApp extends StatefulWidget {
  const VpnOpenoiaApp({super.key});

  @override
  State<VpnOpenoiaApp> createState() => _VpnOpenoiaAppState();
}

class _VpnOpenoiaAppState extends State<VpnOpenoiaApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  void _toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    const primaryBrandColor = Color(0xFF15803D);
    return MaterialApp(
      title: 'Openoia',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryBrandColor,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryBrandColor,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B1120),
      ),
      home: VpnDashboardPage(
        isDark: _themeMode == ThemeMode.dark,
        onToggleTheme: _toggleTheme,
      ),
    );
  }
}

enum VpnState { disconnected, connecting, connected }

class HistorySession {
  final int id;
  final String timestamp;
  final String username;
  String ip;
  String duration;
  String status;

  HistorySession({
    required this.id,
    required this.timestamp,
    required this.username,
    required this.ip,
    required this.duration,
    required this.status,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp,
        'username': username,
        'ip': ip,
        'duration': duration,
        'status': status,
      };

  factory HistorySession.fromJson(Map<String, dynamic> json) {
    return HistorySession(
      id: (json['id'] as num?)?.toInt() ?? 0,
      timestamp: json['timestamp']?.toString() ?? '-',
      username: json['username']?.toString() ?? '-',
      ip: json['ip']?.toString() ?? '-',
      duration: json['duration']?.toString() ?? '00:00:00',
      status: json['status']?.toString() ?? '-',
    );
  }
}

class VpnDashboardPage extends StatefulWidget {
  final bool isDark;
  final VoidCallback onToggleTheme;

  const VpnDashboardPage({
    super.key,
    required this.isDark,
    required this.onToggleTheme,
  });

  @override
  State<VpnDashboardPage> createState() => _VpnDashboardPageState();
}

class _VpnDashboardPageState extends State<VpnDashboardPage> {
  final TextEditingController _ovpnCtrl = TextEditingController();
  final TextEditingController _userCtrl = TextEditingController();
  final TextEditingController _passCtrl = TextEditingController();
  final ScrollController _logScrollCtrl = ScrollController();

  bool _rememberUser = true;
  bool _rememberPass = false;
  bool _obscurePass = true;
  int _selectedMainModule = 0; // 0 = VPN Openoia, 1 = SSH & SFTP
  bool _showVpnLeftSidebar = true;
  bool _showVpnRightSidebar = true;

  VpnState _vpnState = VpnState.disconnected;
  String _statusDetail = 'Pronto para conectar';
  String _assignedIp = '-';
  DateTime? _connectedSince;
  String _durationText = '00:00:00';
  Timer? _clockTimer;

  Process? _vpnProcess;
  bool _userRequestedStop = false;
  int? _currentSessionId;

  final List<HistorySession> _history = [];
  final List<String> _logs = [];

  late final String _homeDir;
  late final Directory _configDir;
  late final Directory _runDir;
  late final SecureStorageVault _vault;
  late final File _settingsFile;
  late final File _historyFile;
  late final File _encryptedProfileFile;
  late final File _lastLogFile;
  late final File _stateFile;

  @override
  void initState() {
    super.initState();
    _homeDir = Platform.environment['HOME'] ?? '/tmp';
    _configDir = Directory('$_homeDir/.config/vpn-openoia');
    _runDir = Directory('${_configDir.path}/run');
    _vault = SecureStorageVault(_configDir);
    _settingsFile = File('${_configDir.path}/settings.json');
    _historyFile = File('${_configDir.path}/history.json');
    _encryptedProfileFile = File('${_configDir.path}/vpn_profile.ovpn.enc');
    _lastLogFile = File('${_configDir.path}/last_connection.log.enc');
    _stateFile = File('${_runDir.path}/state_$pid');

    _initDirectoriesAndLoad();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_vpnState == VpnState.connected && _connectedSince != null) {
        setState(() {
          _durationText = _formatElapsed();
        });
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _disconnectVpn(isDisposing: true);
    _ovpnCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _logScrollCtrl.dispose();
    super.dispose();
  }

  void _initDirectoriesAndLoad() {
    try {
      _configDir.createSync(recursive: true);
      _runDir.createSync(recursive: true);
      Process.runSync('chmod', ['700', _configDir.path]);
      Process.runSync('chmod', ['700', _runDir.path]);

      // Remove legacy plaintext log file if it exists
      final legacyPlainLog = File('${_configDir.path}/last_connection.log');
      if (legacyPlainLog.existsSync()) {
        final content = legacyPlainLog.readAsStringSync();
        _vault.writeEncryptedTextFile(_lastLogFile, content);
        legacyPlainLog.deleteSync();
      }
    } catch (_) {}

    String ovpnPath = '';
    if (_settingsFile.existsSync()) {
      try {
        final data = _vault.readEncryptedJson(_settingsFile);
        if (data is Map<String, dynamic>) {
          final savedOvpn = data['ovpn_path']?.toString() ?? '';
          if (savedOvpn.isNotEmpty) {
            ovpnPath = savedOvpn;
          }
          _userCtrl.text = data['username']?.toString() ?? '';
          _rememberUser = data['remember_user'] as bool? ?? true;
          _rememberPass = data['remember_pass'] as bool? ?? false;

          // Migrate legacy password from settings.json into Linux Secret Service (libsecret)
          final legacyPass = data['password']?.toString() ?? '';
          if (legacyPass.isNotEmpty) {
            _vault.setSecret('vpn_password', legacyPass);
            _passCtrl.text = legacyPass;
            // Re-save settings.json without the 'password' field
            data.remove('password');
            _vault.writeEncryptedJson(_settingsFile, data);
          } else if (_rememberPass) {
            _passCtrl.text = _vault.getSecret('vpn_password');
          }
        }
      } catch (_) {}
    }
    _ovpnCtrl.text = ovpnPath;

    // Cache/encrypt the selected .ovpn profile inside the local encrypted vault
    if (ovpnPath.isNotEmpty && File(ovpnPath).existsSync()) {
      try {
        final rawOvpn = File(ovpnPath).readAsStringSync();
        _vault.writeEncryptedTextFile(_encryptedProfileFile, rawOvpn);
      } catch (_) {}
    }

    if (_historyFile.existsSync()) {
      try {
        final rawList = _vault.readEncryptedJson(_historyFile);
        if (rawList is List) {
          _history.clear();
          bool fixedStale = false;
          for (final item in rawList) {
            if (item is Map<String, dynamic>) {
              final session = HistorySession.fromJson(item);
              if (session.status.contains('Conectado') ||
                  session.status.contains('Conectando') ||
                  session.duration == 'Em andamento') {
                session.status = 'Desconectado ao sair';
                if (session.duration == 'Em andamento') {
                  session.duration = '-';
                }
                fixedStale = true;
              }
              _history.add(session);
            }
          }
          if (fixedStale) {
            _saveHistory();
          }
        }
      } catch (_) {}
    }

    _appendLog(ovpnPath.isEmpty
        ? 'Sistema pronto. Selecione um arquivo .ovpn para conectar.'
        : 'Sistema pronto. Perfil configurado: $ovpnPath');
  }

  /// Saves non-sensitive settings in encrypted settings.json and stores VPN password
  /// exclusively in the Linux Secret Service (libsecret / GNOME Keyring).
  void _saveSettings() {
    final ovpnPath = _ovpnCtrl.text.trim();
    if (ovpnPath.isNotEmpty && File(ovpnPath).existsSync()) {
      try {
        final rawOvpn = File(ovpnPath).readAsStringSync();
        _vault.writeEncryptedTextFile(_encryptedProfileFile, rawOvpn);
      } catch (_) {}
    }

    // Store or clear password in Linux Secret Service (libsecret / GNOME Keyring)
    _vault.setSecret('vpn_password', _rememberPass ? _passCtrl.text : '');

    final data = {
      'ovpn_path': ovpnPath,
      'username': _rememberUser ? _userCtrl.text.trim() : '',
      'remember_user': _rememberUser,
      'remember_pass': _rememberPass,
    };
    _vault.writeEncryptedJson(_settingsFile, data);
  }

  void _saveHistory() {
    final list = _history.take(200).map((e) => e.toJson()).toList();
    _vault.writeEncryptedJson(_historyFile, list);
  }

  String _nowFormatted() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${p(n.day)}/${p(n.month)}/${n.year} ${p(n.hour)}:${p(n.minute)}:${p(n.second)}';
  }

  String _timeOnlyFormatted() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${p(n.hour)}:${p(n.minute)}:${p(n.second)}';
  }

  String _formatElapsed() {
    if (_connectedSince == null) return '00:00:00';
    final diff = DateTime.now().difference(_connectedSince!);
    String p(int v) => v.toString().padLeft(2, '0');
    final h = diff.inHours;
    final m = diff.inMinutes.remainder(60);
    final s = diff.inSeconds.remainder(60);
    return '${p(h)}:${p(m)}:${p(s)}';
  }

  void _appendLog(String line) {
    final formatted = '[${_timeOnlyFormatted()}] ${line.trimRight()}';
    if (mounted) {
      setState(() {
        _logs.add(formatted);
        if (_logs.length > 600) {
          _logs.removeAt(0);
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScrollCtrl.hasClients) {
          _logScrollCtrl.jumpTo(_logScrollCtrl.position.maxScrollExtent);
        }
      });
    }
    try {
      _vault.writeEncryptedTextFile(_lastLogFile, '${_logs.join('\n')}\n');
    } catch (_) {}
  }

  Future<void> _browseOvpnFile() async {
    try {
      final res = await Process.run('zenity', [
        '--file-selection',
        '--title=Selecionar arquivo .ovpn',
        '--file-filter=Arquivos OpenVPN (*.ovpn) | *.ovpn',
      ]);
      if (res.exitCode == 0) {
        final chosen = res.stdout.toString().trim();
        if (chosen.isNotEmpty) {
          setState(() {
            _ovpnCtrl.text = chosen;
          });
          _saveSettings();
        }
      }
    } catch (_) {}
  }

  void _cleanupRunFiles() {
    try {
      _stateFile.writeAsStringSync('DISCONNECTED\n');
    } catch (_) {}
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor:
            isError ? const Color(0xFFDC2626) : const Color(0xFF15803D),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _toggleConnection() async {
    if (_vpnState == VpnState.connecting || _vpnState == VpnState.connected) {
      _disconnectVpn();
    } else {
      await _connectVpn();
    }
  }

  Future<void> _connectVpn() async {
    final ovpnPath = _ovpnCtrl.text.trim();
    final username = _userCtrl.text.trim();
    final password = _passCtrl.text;

    String? ovpnContent;
    if (ovpnPath.isNotEmpty && File(ovpnPath).existsSync()) {
      try {
        ovpnContent = File(ovpnPath).readAsStringSync();
        _vault.writeEncryptedTextFile(_encryptedProfileFile, ovpnContent);
      } catch (_) {}
    } else if (_encryptedProfileFile.existsSync()) {
      ovpnContent = _vault.readEncryptedTextFile(_encryptedProfileFile);
    }

    if (ovpnContent == null || ovpnContent.trim().isEmpty) {
      _showSnack(
          ovpnPath.isEmpty
              ? 'Selecione um arquivo .ovpn antes de conectar.'
              : 'Arquivo .ovpn não encontrado em: $ovpnPath',
          isError: true);
      return;
    }

    if (username.isEmpty || password.isEmpty) {
      _showSnack('Preencha o Usuário e a Senha da VPN para conectar.',
          isError: true);
      return;
    }

    _saveSettings();
    _cleanupRunFiles();

    final sessionId = DateTime.now().millisecondsSinceEpoch;
    final session = HistorySession(
      id: sessionId,
      timestamp: _nowFormatted(),
      username: username,
      ip: '-',
      duration: '00:00:00',
      status: 'Conectando...',
    );

    setState(() {
      _userRequestedStop = false;
      _vpnState = VpnState.connecting;
      _statusDetail = 'Estabelecendo túnel...';
      _assignedIp = '-';
      _connectedSince = null;
      _durationText = '00:00:00';
      _currentSessionId = sessionId;
      _history.insert(0, session);
    });
    _saveHistory();

    _appendLog('================================================');
    _appendLog('Iniciando conexão VPN Openoia para "$username"...');

    // Hardened root installer/runner:
    // - Never accepts arbitrary file paths to delete or execute
    // - Sanitizes the .ovpn profile into /etc/openvpn/client/openoia/active.conf (0600, root:root)
    // - Enforces --script-security 0 and fixed arguments
    const rootInstaller = r'''
GUI_PID="$1"
HELPER_PATH="/usr/local/bin/vpn-openoia-root-helper"
SUDOERS_PATH="/etc/sudoers.d/vpn-openoia"

cat << 'EOF_HELPER' > "$HELPER_PATH"
#!/usr/bin/env python3
import json
import os
import re
import signal
import subprocess
import sys
import time

PROTECTED_CONF_DIR = "/etc/openvpn/client/openoia"
PROTECTED_CONF_FILE = "/etc/openvpn/client/openoia/active.conf"
PROTECTED_RUN_DIR = "/run/vpn-openoia"
PROTECTED_AUTH_FILE = "/run/vpn-openoia/auth"
PROTECTED_PID_FILE = "/run/vpn-openoia/openvpn.pid"

FORBIDDEN_DIRECTIVES = {
    "script-security",
    "up",
    "down",
    "route-up",
    "route-pre-down",
    "ipchange",
    "client-connect",
    "client-disconnect",
    "learn-address",
    "auth-user-pass-verify",
    "tls-verify",
    "plugin",
    "management",
    "log",
    "log-append",
    "status",
    "cd",
    "chroot",
    "daemon",
    "writepid",
}

def sanitize_ovpn(raw_text: str) -> str:
    sanitized_lines = []
    in_inline_block = False
    for raw_line in raw_text.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith(";"):
            continue
        lower = stripped.lower()
        if re.match(r"^<(ca|cert|key|tls-auth|tls-crypt|extra-certs)>", lower):
            in_inline_block = True
            sanitized_lines.append(stripped)
            continue
        if re.match(r"^</(ca|cert|key|tls-auth|tls-crypt|extra-certs)>", lower):
            in_inline_block = False
            sanitized_lines.append(stripped)
            continue
        if in_inline_block:
            sanitized_lines.append(raw_line)
            continue

        parts = stripped.split()
        directive = parts[0].lower()
        if directive in FORBIDDEN_DIRECTIVES:
            continue
        if directive == "auth-user-pass":
            continue
        sanitized_lines.append(stripped)
    return "\n".join(sanitized_lines) + "\n"

def stop_verified_openvpn():
    if not os.path.exists(PROTECTED_PID_FILE):
        return
    try:
        with open(PROTECTED_PID_FILE, "r", encoding="utf-8") as f:
            pid = int(f.read().strip())
        comm_path = f"/proc/{pid}/comm"
        if os.path.exists(comm_path):
            with open(comm_path, "r", encoding="utf-8") as cf:
                if cf.read().strip() == "openvpn":
                    os.kill(pid, signal.SIGTERM)
    except Exception:
        pass
    try:
        if os.path.exists(PROTECTED_PID_FILE):
            os.remove(PROTECTED_PID_FILE)
    except Exception:
        pass

def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--check-v2":
        sys.exit(0)

    if len(sys.argv) >= 2 and sys.argv[1] == "--disconnect":
        stop_verified_openvpn()
        sys.exit(0)

    if len(sys.argv) < 3 or sys.argv[1] != "--connect":
        sys.exit(2)

    try:
        gui_pid = int(sys.argv[2])
    except ValueError:
        sys.exit(2)

    payload_raw = sys.stdin.read()
    try:
        payload = json.loads(payload_raw)
    except Exception:
        sys.exit(3)

    ovpn_raw = str(payload.get("ovpn", ""))
    username = str(payload.get("username", "")).replace("\n", "").replace("\r", "")
    password = str(payload.get("password", "")).replace("\n", "").replace("\r", "")
    if not ovpn_raw or not username or not password:
        sys.exit(3)

    os.makedirs(PROTECTED_CONF_DIR, mode=0o700, exist_ok=True)
    os.chown(PROTECTED_CONF_DIR, 0, 0)
    os.chmod(PROTECTED_CONF_DIR, 0o700)

    os.makedirs(PROTECTED_RUN_DIR, mode=0o700, exist_ok=True)
    os.chown(PROTECTED_RUN_DIR, 0, 0)
    os.chmod(PROTECTED_RUN_DIR, 0o700)

    sanitized_conf = sanitize_ovpn(ovpn_raw)
    with open(PROTECTED_CONF_FILE, "w", encoding="utf-8") as cf:
        cf.write(sanitized_conf)
    os.chown(PROTECTED_CONF_FILE, 0, 0)
    os.chmod(PROTECTED_CONF_FILE, 0o600)

    with open(PROTECTED_AUTH_FILE, "w", encoding="utf-8") as af:
        af.write(f"{username}\n{password}\n")
    os.chown(PROTECTED_AUTH_FILE, 0, 0)
    os.chmod(PROTECTED_AUTH_FILE, 0o600)

    stop_verified_openvpn()

    proc = subprocess.Popen(
        [
            "/usr/sbin/openvpn",
            "--config", PROTECTED_CONF_FILE,
            "--script-security", "0",
            "--data-ciphers", "AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-128-CBC",
            "--data-ciphers-fallback", "AES-128-CBC",
            "--auth-user-pass", PROTECTED_AUTH_FILE,
            "--auth-retry", "nointeract",
        ]
    )

    with open(PROTECTED_PID_FILE, "w", encoding="utf-8") as pf:
        pf.write(str(proc.pid))
    os.chmod(PROTECTED_PID_FILE, 0o600)

    def handle_sig(signum, frame):
        try:
            proc.terminate()
        except Exception:
            pass

    signal.signal(signal.SIGTERM, handle_sig)
    signal.signal(signal.SIGINT, handle_sig)

    start_ts = time.time()
    auth_removed = False
    try:
        while proc.poll() is None:
            if not auth_removed and (time.time() - start_ts) > 2.0:
                try:
                    if os.path.exists(PROTECTED_AUTH_FILE):
                        os.remove(PROTECTED_AUTH_FILE)
                except Exception:
                    pass
                auth_removed = True

            if not os.path.exists(f"/proc/{gui_pid}"):
                proc.terminate()
                break
            time.sleep(0.25)
    finally:
        for p in (PROTECTED_AUTH_FILE, PROTECTED_PID_FILE, PROTECTED_CONF_FILE):
            try:
                if os.path.exists(p):
                    os.remove(p)
            except Exception:
                pass

    sys.exit(proc.wait())

if __name__ == "__main__":
    main()
EOF_HELPER

chown root:root "$HELPER_PATH"
chmod 755 "$HELPER_PATH"
echo "ALL ALL=(root) NOPASSWD: $HELPER_PATH" > "$SUDOERS_PATH"
chown root:root "$SUDOERS_PATH"
chmod 440 "$SUDOERS_PATH"

exec "$HELPER_PATH" --connect "$GUI_PID"
''';

    final cleanEnv = Map<String, String>.from(Platform.environment);
    cleanEnv.remove('LD_LIBRARY_PATH');
    cleanEnv.remove('PYTHONHOME');
    cleanEnv.remove('PYTHONPATH');

    const helperPath = '/usr/local/bin/vpn-openoia-root-helper';
    final check = await Process.run(
      'sudo',
      ['-n', helperPath, '--check-v2'],
      environment: cleanEnv,
    );

    final String executable;
    final List<String> fullArgs;
    if (check.exitCode == 0) {
      executable = 'sudo';
      fullArgs = [
        '-n',
        helperPath,
        '--connect',
        pid.toString(),
      ];
    } else {
      executable = 'pkexec';
      fullArgs = [
        '/bin/bash',
        '-c',
        rootInstaller,
        'vpn-openoia-setup',
        pid.toString(),
      ];
    }

    bool authFailed = false;
    int exitCode = -1;

    try {
      final proc = await Process.start(
        executable,
        fullArgs,
        environment: cleanEnv,
      );
      _vpnProcess = proc;

      // Feed sanitized payload via stdin pipe (no temporary user files on disk)
      final payloadJson = jsonEncode({
        'ovpn': ovpnContent,
        'username': username,
        'password': password,
      });
      proc.stdin.writeln(payloadJson);
      await proc.stdin.close();

      void handleStream(Stream<List<int>> stream) {
        stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
          if (line.trim().isEmpty) return;
          _appendLog(line);

          final ipMatch = RegExp(
            r'(?:ifconfig\s+|net_addr_v4_add:\s+|ip addr add dev tun\d+\s+|ifconfig-push\s+)(\d+\.\d+\.\d+\.\d+)',
          ).firstMatch(line);
          if (ipMatch != null) {
            final ip = ipMatch.group(1)!;
            if (mounted) {
              setState(() {
                _assignedIp = ip;
              });
              _updateCurrentSession(ip: ip);
            }
          }

          if (line.contains('SIGTERM') && _userRequestedStop) {
            _updateCurrentSession(
              ip: _assignedIp,
              duration: _formatElapsed(),
              status: 'Desconectado pelo usuário',
            );
          }

          if (line.contains('Initialization Sequence Completed')) {
            try {
              _stateFile.writeAsStringSync('CONNECTED\n');
            } catch (_) {}
            if (mounted) {
              setState(() {
                _connectedSince = DateTime.now();
                _vpnState = VpnState.connected;
                _statusDetail = 'Túnel Ativo e Criptografado';
              });
              _updateCurrentSession(
                ip: _assignedIp,
                duration: 'Em andamento',
                status: '🟢 Conectado',
              );
              _showSnack('VPN Openoia conectada com sucesso!');
            }
          }

          if (line.contains('AUTH_FAILED')) {
            authFailed = true;
          }
        });
      }

      handleStream(proc.stdout);
      handleStream(proc.stderr);

      exitCode = await proc.exitCode;
    } catch (e) {
      _appendLog('Erro ao iniciar OpenVPN: $e');
    } finally {
      _vpnProcess = null;
      _cleanupRunFiles();
    }

    if (!mounted) return;

    final finalDur = _formatElapsed();
    final wasConnected = _connectedSince != null;
    _connectedSince = null;

    String finalStatus;
    String detail;
    if (_userRequestedStop) {
      finalStatus = 'Desconectado pelo usuário';
      detail = 'Desconectado';
    } else if (authFailed) {
      finalStatus = '❌ Usuário ou senha incorretos';
      detail = 'Falha de autenticação';
      _showSnack('Falha na autenticação: verifique seu usuário e senha da VPN.',
          isError: true);
    } else if (exitCode == 126 || exitCode == 127) {
      finalStatus = 'Autorização cancelada';
      detail = 'Permissão negada';
    } else if (wasConnected) {
      finalStatus = 'Sessão encerrada';
      detail = 'Desconectado';
    } else {
      finalStatus = 'Falha na conexão (cód. $exitCode)';
      detail = 'Erro ao conectar';
    }

    setState(() {
      _vpnState = VpnState.disconnected;
      _statusDetail = detail;
    });
    _updateCurrentSession(
      ip: _assignedIp,
      duration: finalDur,
      status: finalStatus,
    );
    _appendLog('Sessão finalizada: $finalStatus (Duração: $finalDur)');
  }

  void _updateCurrentSession({
    String? ip,
    String? duration,
    String? status,
  }) {
    if (_currentSessionId == null) return;
    for (final s in _history) {
      if (s.id == _currentSessionId) {
        if (ip != null) s.ip = ip;
        if (duration != null) s.duration = duration;
        if (status != null) s.status = status;
        break;
      }
    }
    if (mounted) setState(() {});
    _saveHistory();
  }

  void _disconnectVpn({bool isDisposing = false}) {
    _userRequestedStop = true;
    if (!isDisposing) {
      _appendLog('Encerrando conexão VPN...');
    }
    if (_vpnProcess != null) {
      try {
        final cleanEnv = Map<String, String>.from(Platform.environment)
          ..remove('LD_LIBRARY_PATH')
          ..remove('PYTHONHOME')
          ..remove('PYTHONPATH');
        Process.runSync(
          'sudo',
          ['-n', '/usr/local/bin/vpn-openoia-root-helper', '--disconnect'],
          environment: cleanEnv,
        );
        _vpnProcess?.kill(ProcessSignal.sigterm);
        _vpnProcess = null;
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final cardBg = isDark ? const Color(0xFF162032) : Colors.white;
    final borderCol =
        isDark ? const Color(0xFF26354D) : const Color(0xFFE2E8F0);
    final textPrimary = isDark ? Colors.white : const Color(0xFF0F172A);
    final textSecondary =
        isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Scaffold(
      body: Column(
        children: [
          _buildHeroHeader(),
          Expanded(
            child: IndexedStack(
              index: _selectedMainModule,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_showVpnLeftSidebar) ...[
                        if (_showVpnRightSidebar)
                          SizedBox(
                            width: 350,
                            child: _buildControlCard(
                              cardBg: cardBg,
                              borderCol: borderCol,
                              textPrimary: textPrimary,
                              textSecondary: textSecondary,
                            ),
                          )
                        else
                          Expanded(
                            child: _buildControlCard(
                              cardBg: cardBg,
                              borderCol: borderCol,
                              textPrimary: textPrimary,
                              textSecondary: textSecondary,
                            ),
                          ),
                      ] else ...[
                        _buildCollapsedSidebarStrip(
                          isLeft: true,
                          label: 'Credenciais VPN',
                          cardBg: cardBg,
                          borderCol: borderCol,
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                          onTap: () =>
                              setState(() => _showVpnLeftSidebar = true),
                        ),
                      ],
                      const SizedBox(width: 12),
                      if (_showVpnRightSidebar) ...[
                        Expanded(
                          child: Column(
                            children: [
                              _buildMetricsRow(
                                cardBg: cardBg,
                                borderCol: borderCol,
                                textPrimary: textPrimary,
                                textSecondary: textSecondary,
                              ),
                              const SizedBox(height: 14),
                              Expanded(
                                child: _buildHistoryAndLogsCard(
                                  cardBg: cardBg,
                                  borderCol: borderCol,
                                  textPrimary: textPrimary,
                                  textSecondary: textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        _buildCollapsedSidebarStrip(
                          isLeft: false,
                          label: 'Histórico & Logs',
                          cardBg: cardBg,
                          borderCol: borderCol,
                          textPrimary: textPrimary,
                          textSecondary: textSecondary,
                          onTap: () =>
                              setState(() => _showVpnRightSidebar = true),
                        ),
                      ],
                    ],
                  ),
                ),
                SshWorkspacePage(
                  isDark: isDark,
                  configDir: _configDir,
                ),
                DbWorkspacePage(
                  isDark: isDark,
                  configDir: _configDir,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroHeader() {
    Color badgeColor;
    String badgeText;
    IconData badgeIcon;

    switch (_vpnState) {
      case VpnState.disconnected:
        badgeColor = Colors.white.withValues(alpha: 0.16);
        badgeText = 'Desconectado';
        badgeIcon = Icons.shield_outlined;
        break;
      case VpnState.connecting:
        badgeColor = const Color(0xFFF59E0B);
        badgeText = 'Conectando...';
        badgeIcon = Icons.sync_rounded;
        break;
      case VpnState.connected:
        badgeColor = const Color(0xFF22C55E);
        badgeText = 'Conectado';
        badgeIcon = Icons.verified_user_rounded;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0A3D22), Color(0xFF146C3B), Color(0xFF1B8A4C)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Icon(
                  Icons.vpn_lock_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
              if (_vpnState == VpnState.connected)
                Positioned(
                  right: -3,
                  bottom: -3,
                  child: Container(
                    width: 15,
                    height: 15,
                    decoration: BoxDecoration(
                      color: const Color(0xFF4ADE80),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF0A3D22),
                        width: 2.5,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x994ADE80),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Openoia',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Cliente OpenVPN + SSH & SFTP + DataBase Studio',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(0xFFD1FAE5),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.24),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildModuleSwitchButton(
                  index: 0,
                  icon: Icons.shield_outlined,
                  label: 'VPN',
                ),
                const SizedBox(width: 4),
                _buildModuleSwitchButton(
                  index: 1,
                  icon: Icons.terminal_rounded,
                  label: 'SSH & SFTP',
                ),
                const SizedBox(width: 4),
                _buildModuleSwitchButton(
                  index: 2,
                  icon: Icons.storage_rounded,
                  label: 'DataBase',
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            onPressed: widget.onToggleTheme,
            tooltip:
                widget.isDark ? 'Mudar para Tema Claro' : 'Mudar para Tema Escuro',
            icon: Icon(
              widget.isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: badgeColor,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white30),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_vpnState == VpnState.connected)
                  Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  )
                else ...[
                  Icon(badgeIcon, color: Colors.white, size: 16),
                  const SizedBox(width: 6),
                ],
                Text(
                  badgeText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModuleSwitchButton({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final active = _selectedMainModule == index;
    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: () => setState(() => _selectedMainModule = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: active ? const Color(0xFF0A3D22) : Colors.white,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: active ? const Color(0xFF0A3D22) : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlCard({
    required Color cardBg,
    required Color borderCol,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    final isBusy =
        _vpnState == VpnState.connecting || _vpnState == VpnState.connected;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderCol),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.tune_rounded, size: 19, color: textPrimary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Credenciais e Perfil',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: textPrimary,
                  ),
                ),
              ),
              if (_showVpnRightSidebar)
                IconButton(
                  onPressed: () =>
                      setState(() => _showVpnLeftSidebar = false),
                  tooltip: 'Ocultar Sidebar Esquerda',
                  visualDensity: VisualDensity.compact,
                  icon: SidebarToggleIcon(
                    isLeft: true,
                    isOpen: true,
                    color: textSecondary,
                    size: 18,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Arquivo de Configuração (.ovpn)',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ovpnCtrl,
                  enabled: !isBusy,
                  style: TextStyle(fontSize: 12.5, color: textPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 11,
                    ),
                    prefixIcon:
                        const Icon(Icons.insert_drive_file_outlined, size: 18),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: isBusy ? null : _browseOvpnFile,
                icon: const Icon(Icons.folder_open_rounded, size: 17),
                label: const Text('Abrir'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Usuário da VPN',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _userCtrl,
            enabled: !isBusy,
            style: TextStyle(fontSize: 14, color: textPrimary),
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              hintText: 'Digite seu usuário',
              prefixIcon: const Icon(Icons.person_outline_rounded, size: 20),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 13,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Senha da VPN',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _passCtrl,
            enabled: !isBusy,
            obscureText: _obscurePass,
            style: TextStyle(fontSize: 14, color: textPrimary),
            onSubmitted: (_) => _toggleConnection(),
            decoration: InputDecoration(
              hintText: 'Digite sua senha',
              prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
              suffixIcon: IconButton(
                onPressed: () {
                  setState(() {
                    _obscurePass = !_obscurePass;
                  });
                },
                tooltip: _obscurePass ? 'Mostrar senha' : 'Ocultar senha',
                icon: Icon(
                  _obscurePass
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 19,
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 13,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 12),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: isBusy
                ? null
                : () {
                    setState(() => _rememberUser = !_rememberUser);
                    _saveSettings();
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: _rememberUser,
                      onChanged: isBusy
                          ? null
                          : (val) {
                              setState(() => _rememberUser = val ?? true);
                              _saveSettings();
                            },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Lembrar meu usuário',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: isBusy
                ? null
                : () {
                    setState(() => _rememberPass = !_rememberPass);
                    _saveSettings();
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: _rememberPass,
                      onChanged: isBusy
                          ? null
                          : (val) {
                              setState(() => _rememberPass = val ?? false);
                              _saveSettings();
                            },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Salvar minha senha neste PC',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          SizedBox(
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _toggleConnection,
              style: ElevatedButton.styleFrom(
                backgroundColor: isBusy
                    ? const Color(0xFFDC2626)
                    : const Color(0xFF15803D),
                foregroundColor: Colors.white,
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: Icon(
                isBusy
                    ? Icons.power_off_rounded
                    : Icons.power_settings_new_rounded,
                size: 22,
              ),
              label: Text(
                _vpnState == VpnState.disconnected
                    ? 'CONECTAR VPN'
                    : (_vpnState == VpnState.connecting
                        ? 'CANCELAR CONEXÃO'
                        : 'DESCONECTAR VPN'),
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsRow({
    required Color cardBg,
    required Color borderCol,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    return Row(
      children: [
        Expanded(
          child: _metricTile(
            cardBg: cardBg,
            borderCol: borderCol,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
            icon: Icons.sensors_rounded,
            iconColor: _vpnState == VpnState.connected
                ? const Color(0xFF22C55E)
                : (_vpnState == VpnState.connecting
                    ? const Color(0xFFF59E0B)
                    : textSecondary),
            label: 'STATUS DA REDE',
            value: _statusDetail,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _metricTile(
            cardBg: cardBg,
            borderCol: borderCol,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
            icon: Icons.lan_rounded,
            iconColor: const Color(0xFF3B82F6),
            label: 'IP DA VPN (TUN)',
            value: _assignedIp,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _metricTile(
            cardBg: cardBg,
            borderCol: borderCol,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
            icon: Icons.timer_outlined,
            iconColor: const Color(0xFF10B981),
            label: 'TEMPO CONECTADO',
            value: _durationText,
          ),
        ),
      ],
    );
  }

  Widget _metricTile({
    required Color cardBg,
    required Color borderCol,
    required Color textPrimary,
    required Color textSecondary,
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderCol),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: textSecondary,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryAndLogsCard({
    required Color cardBg,
    required Color borderCol,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    return DefaultTabController(
      length: 2,
      child: Container(
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderCol),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: borderCol)),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      dividerColor: Colors.transparent,
                      tabs: [
                        Tab(
                          child: Row(
                            children: [
                              Icon(Icons.history_rounded, size: 18),
                              SizedBox(width: 7),
                              Text('Histórico de Conexões'),
                            ],
                          ),
                        ),
                        Tab(
                          child: Row(
                            children: [
                              Icon(Icons.terminal_rounded, size: 18),
                              SizedBox(width: 7),
                              Text('Log em Tempo Real'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: _logs.join('\n')),
                      );
                      _showSnack('Log copiado para a área de transferência.');
                    },
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label:
                        const Text('Copiar Log', style: TextStyle(fontSize: 12)),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _history.clear();
                      });
                      _saveHistory();
                    },
                    icon: const Icon(Icons.delete_outline_rounded, size: 16),
                    label: const Text('Limpar Histórico',
                        style: TextStyle(fontSize: 12)),
                  ),
                  if (_showVpnLeftSidebar)
                    IconButton(
                      onPressed: () =>
                          setState(() => _showVpnRightSidebar = false),
                      tooltip: 'Ocultar Sidebar Direita',
                      visualDensity: VisualDensity.compact,
                      icon: SidebarToggleIcon(
                        isLeft: false,
                        isOpen: true,
                        color: textSecondary,
                        size: 18,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _buildHistoryList(
                    textPrimary: textPrimary,
                    textSecondary: textSecondary,
                    borderCol: borderCol,
                  ),
                  _buildLiveLogConsole(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollapsedSidebarStrip({
    required bool isLeft,
    required String label,
    required Color cardBg,
    required Color borderCol,
    required Color textPrimary,
    required Color textSecondary,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        width: 42,
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderCol),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SidebarToggleIcon(
              isLeft: isLeft,
              isOpen: false,
              color: const Color(0xFF22C55E),
              size: 19,
            ),
            const SizedBox(height: 12),
            RotatedBox(
              quarterTurns: isLeft ? 3 : 1,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: textPrimary,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryList({
    required Color textPrimary,
    required Color textSecondary,
    required Color borderCol,
  }) {
    if (_history.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_toggle_off_rounded,
                size: 44, color: textSecondary.withValues(alpha: 0.5)),
            const SizedBox(height: 10),
            Text(
              'Nenhuma conexão registrada ainda.',
              style: TextStyle(color: textSecondary, fontSize: 13.5),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _history.length,
      separatorBuilder: (_, __) => Divider(color: borderCol, height: 1),
      itemBuilder: (context, idx) {
        final item = _history[idx];
        final isOk = item.status.contains('Conectado');
        final isErr =
            item.status.contains('Falha') || item.status.contains('incorretos');

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Row(
            children: [
              Icon(
                isOk
                    ? Icons.check_circle_rounded
                    : (isErr
                        ? Icons.error_outline_rounded
                        : Icons.info_outline_rounded),
                size: 20,
                color: isOk
                    ? const Color(0xFF22C55E)
                    : (isErr
                        ? const Color(0xFFEF4444)
                        : const Color(0xFF3B82F6)),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 138,
                child: Text(
                  item.timestamp,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              SizedBox(
                width: 95,
                child: Text(
                  item.username,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: textPrimary,
                  ),
                ),
              ),
              SizedBox(
                width: 105,
                child: Text(
                  'IP: ${item.ip}',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: textSecondary,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              SizedBox(
                width: 80,
                child: Text(
                  item.duration,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: textSecondary,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  item.status,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: isOk
                        ? const Color(0xFF22C55E)
                        : (isErr ? const Color(0xFFEF4444) : textPrimary),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLiveLogConsole() {
    return Container(
      margin: const EdgeInsets.all(10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF090D16),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: ListView.builder(
        controller: _logScrollCtrl,
        itemCount: _logs.length,
        itemBuilder: (context, idx) {
          final line = _logs[idx];
          Color lineColor = const Color(0xFFCBD5E1);
          if (line.contains('Initialization Sequence Completed')) {
            lineColor = const Color(0xFF4ADE80);
          } else if (line.contains('AUTH_FAILED') ||
              line.contains('Erro') ||
              line.contains('error')) {
            lineColor = const Color(0xFFF87171);
          } else if (line.contains('ifconfig') || line.contains('PUSH_REPLY')) {
            lineColor = const Color(0xFF38BDF8);
          }
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: SelectableText(
              line,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                color: lineColor,
              ),
            ),
          );
        },
      ),
    );
  }
}

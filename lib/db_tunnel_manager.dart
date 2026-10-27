import 'dart:async';
import 'dart:io';
import 'ssh_models.dart';

/// Manages dynamic SSH Tunnels (port forwarding) for database connections
class DbTunnelManager {
  final SshHelperManager sshHelper;
  final List<Process> _activeTunnels = [];

  DbTunnelManager(this.sshHelper);

  /// Allocates a free ephemeral local port on 127.0.0.1
  Future<int> _findFreePort() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    return port;
  }

  /// Opens an SSH port forwarding tunnel:
  /// `ssh -N -L <localPort>:<remoteDbHost>:<remoteDbPort> <sshArgs> <user@sshAddress>`
  Future<(int localPort, Process tunnelProcess)> openTunnel({
    required SshHostConfig sshHost,
    required String remoteDbHost,
    required int remoteDbPort,
  }) async {
    final localPort = await _findFreePort();
    final commonOpts = await sshHelper.buildCommonSshOptions(sshHost);
    final askPassFile = sshHelper.createAskPassScript(sshHost);

    final cleanEnv = Map<String, String>.from(Platform.environment)
      ..remove('LD_LIBRARY_PATH')
      ..remove('PYTHONHOME')
      ..remove('PYTHONPATH');

    if (askPassFile != null) {
      cleanEnv['SSH_ASKPASS'] = askPassFile.path;
      cleanEnv['SSH_ASKPASS_REQUIRE'] = 'force';
      cleanEnv['DISPLAY'] = cleanEnv['DISPLAY'] ?? ':0';
    }

    final sshArgs = <String>[
      '-N',
      '-L',
      '$localPort:$remoteDbHost:$remoteDbPort',
      '-p',
      sshHost.port.toString(),
      ...commonOpts,
      '${sshHost.username}@${sshHost.address}',
    ];

    final proc = await Process.start(
      'ssh',
      sshArgs,
      environment: cleanEnv,
    );

    _activeTunnels.add(proc);

    // Give SSH half a second to bind or fail
    await Future.delayed(const Duration(milliseconds: 600));

    // Cleanup askpass script
    if (askPassFile != null) {
      try {
        if (askPassFile.existsSync()) askPassFile.deleteSync();
      } catch (_) {}
    }

    return (localPort, proc);
  }

  /// Closes an active SSH tunnel
  void closeTunnel(Process? proc) {
    if (proc == null) return;
    try {
      proc.kill(ProcessSignal.sigterm);
    } catch (_) {}
    _activeTunnels.remove(proc);
  }

  /// Closes all active tunnels
  void closeAll() {
    for (final p in _activeTunnels) {
      try {
        p.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }
    _activeTunnels.clear();
  }
}

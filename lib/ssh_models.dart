import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'secure_storage.dart';

enum SshExtraCredentialType {
  sshId,
  privateKey,
  certificate,
  fido2,
}

extension SshExtraCredentialTypeExt on SshExtraCredentialType {
  String get title {
    switch (this) {
      case SshExtraCredentialType.sshId:
        return 'SSH ID (Passkeys for SSH)';
      case SshExtraCredentialType.privateKey:
        return 'Key (Chave Privada .pem / .ppk / id_rsa)';
      case SshExtraCredentialType.certificate:
        return 'Certificate (Certificado SSH)';
      case SshExtraCredentialType.fido2:
        return 'FIDO2 (Security Key)';
    }
  }
}

class SshHostConfig {
  String id;
  String name;
  String group;
  String address;
  int port;
  String username;

  // Stored in Linux Secret Service (libsecret / GNOME Keyring), NOT in ssh_hosts.json
  String password;

  // Enabled extra credential sections (added via '+' button)
  List<String> enabledExtras; // 'sshId', 'privateKey', 'certificate', 'fido2'

  // Extra credential fields
  String sshId;
  String privateKeyPath;
  String privateKeyContent; // Stored in Linux Secret Service
  String passphrase; // Stored in Linux Secret Service
  String certificatePath;
  String fido2KeyPath;
  String fido2Provider;

  // Advanced SSH fields
  String proxyJump;
  String localForward;
  String remoteForward;
  String startupCommand;
  int keepAliveInterval;
  bool x11Forwarding;
  bool compression;

  SshHostConfig({
    required this.id,
    required this.name,
    this.group = 'Geral',
    required this.address,
    this.port = 22,
    required this.username,
    this.password = '',
    List<String>? enabledExtras,
    this.sshId = '',
    this.privateKeyPath = '',
    this.privateKeyContent = '',
    this.passphrase = '',
    this.certificatePath = '',
    this.fido2KeyPath = '',
    this.fido2Provider = 'internal',
    this.proxyJump = '',
    this.localForward = '',
    this.remoteForward = '',
    this.startupCommand = '',
    this.keepAliveInterval = 30,
    this.x11Forwarding = false,
    this.compression = false,
  }) : enabledExtras = enabledExtras ?? [];

  String get summaryBadge {
    final badges = <String>[];
    if (password.isNotEmpty) badges.add('PASS');
    if (enabledExtras.contains('sshId')) badges.add('SSH ID');
    if (enabledExtras.contains('privateKey')) badges.add('KEY');
    if (enabledExtras.contains('certificate')) badges.add('CERT');
    if (enabledExtras.contains('fido2')) badges.add('FIDO2');
    if (badges.isEmpty) return 'SSH';
    return badges.join(' + ');
  }

  /// Serializes host metadata WITHOUT passwords, passphrases, or private keys.
  /// Credentials are persisted exclusively in Linux Secret Service (libsecret / GNOME Keyring).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'group': group,
        'address': address,
        'port': port,
        'username': username,
        'hasPassword': password.isNotEmpty,
        'enabledExtras': enabledExtras,
        'sshId': sshId,
        'privateKeyPath': privateKeyPath,
        'hasPrivateKeyContent': privateKeyContent.isNotEmpty,
        'hasPassphrase': passphrase.isNotEmpty,
        'certificatePath': certificatePath,
        'fido2KeyPath': fido2KeyPath,
        'fido2Provider': fido2Provider,
        'proxyJump': proxyJump,
        'localForward': localForward,
        'remoteForward': remoteForward,
        'startupCommand': startupCommand,
        'keepAliveInterval': keepAliveInterval,
        'x11Forwarding': x11Forwarding,
        'compression': compression,
      };

  /// Persists sensitive credentials in Linux Secret Service (libsecret / GNOME Keyring).
  void saveSecretsToVault(SecureStorageVault vault) {
    vault.setSecret('ssh_pass_$id', password);
    vault.setSecret('ssh_passphrase_$id', passphrase);
    vault.setSecret('ssh_pk_content_$id', privateKeyContent);
  }

  /// Deletes sensitive credentials from Linux Secret Service when host is deleted.
  void deleteSecretsFromVault(SecureStorageVault vault) {
    vault.deleteSecret('ssh_pass_$id');
    vault.deleteSecret('ssh_passphrase_$id');
    vault.deleteSecret('ssh_pk_content_$id');
  }

  factory SshHostConfig.fromJson(
    Map<String, dynamic> json, {
    SecureStorageVault? vault,
  }) {
    final rawExtras = (json['enabledExtras'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        <String>[];

    final oldAuthType = json['authType']?.toString();
    if (rawExtras.isEmpty && oldAuthType != null && oldAuthType != 'password') {
      if (oldAuthType == 'sshAgent') {
        rawExtras.add('sshId');
      } else {
        rawExtras.add(oldAuthType);
      }
    }

    final hostId = json['id']?.toString() ??
        DateTime.now().millisecondsSinceEpoch.toString();

    String loadedPassword = json['password']?.toString() ?? '';
    String loadedPassphrase = json['passphrase']?.toString() ?? '';
    String loadedPkContent = json['privateKeyContent']?.toString() ?? '';

    if (vault != null) {
      // Migrate any legacy inline secrets into Linux Secret Service (libsecret)
      if (loadedPassword.isNotEmpty) {
        vault.setSecret('ssh_pass_$hostId', loadedPassword);
      } else {
        loadedPassword = vault.getSecret('ssh_pass_$hostId');
      }

      if (loadedPassphrase.isNotEmpty) {
        vault.setSecret('ssh_passphrase_$hostId', loadedPassphrase);
      } else {
        loadedPassphrase = vault.getSecret('ssh_passphrase_$hostId');
      }

      if (loadedPkContent.isNotEmpty) {
        vault.setSecret('ssh_pk_content_$hostId', loadedPkContent);
      } else {
        loadedPkContent = vault.getSecret('ssh_pk_content_$hostId');
      }
    }

    return SshHostConfig(
      id: hostId,
      name: json['name']?.toString() ?? 'Servidor SSH',
      group: json['group']?.toString() ?? 'Geral',
      address: json['address']?.toString() ?? '',
      port: (json['port'] as num?)?.toInt() ?? 22,
      username: json['username']?.toString() ?? 'root',
      password: loadedPassword,
      enabledExtras: rawExtras,
      sshId: json['sshId']?.toString() ?? '',
      privateKeyPath: json['privateKeyPath']?.toString() ?? '',
      privateKeyContent: loadedPkContent,
      passphrase: loadedPassphrase,
      certificatePath: json['certificatePath']?.toString() ?? '',
      fido2KeyPath: json['fido2KeyPath']?.toString() ?? '',
      fido2Provider: json['fido2Provider']?.toString() ?? 'internal',
      proxyJump: json['proxyJump']?.toString() ?? '',
      localForward: json['localForward']?.toString() ?? '',
      remoteForward: json['remoteForward']?.toString() ?? '',
      startupCommand: json['startupCommand']?.toString() ?? '',
      keepAliveInterval: (json['keepAliveInterval'] as num?)?.toInt() ?? 30,
      x11Forwarding: json['x11Forwarding'] as bool? ?? false,
      compression: json['compression'] as bool? ?? false,
    );
  }
}

class SshSnippet {
  String id;
  String title;
  String category;
  String command;
  bool autoEnter;

  SshSnippet({
    required this.id,
    required this.title,
    this.category = 'Geral',
    required this.command,
    this.autoEnter = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'category': category,
        'command': command,
        'autoEnter': autoEnter,
      };

  factory SshSnippet.fromJson(Map<String, dynamic> json) {
    return SshSnippet(
      id: json['id']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      title: json['title']?.toString() ?? 'Comando',
      category: json['category']?.toString() ?? 'Geral',
      command: json['command']?.toString() ?? '',
      autoEnter: json['autoEnter'] as bool? ?? true,
    );
  }
}

class SftpRemoteEntry {
  final String name;
  final String permissions;
  final String size;
  final String date;
  final bool isDirectory;
  final bool isSymlink;

  SftpRemoteEntry({
    required this.name,
    required this.permissions,
    required this.size,
    required this.date,
    required this.isDirectory,
    this.isSymlink = false,
  });
}

class SshHelperManager {
  final Directory configDir;
  late final SecureStorageVault vault;
  late final Directory keysDir;
  late final Directory runDir;
  late final Directory scriptsDir;
  late final File ptyBridgeScript;

  SshHelperManager(this.configDir) {
    vault = SecureStorageVault(configDir);
    keysDir = Directory('${configDir.path}/keys');
    runDir = Directory('${configDir.path}/run');
    scriptsDir = Directory('${configDir.path}/scripts');
    ptyBridgeScript = File('${scriptsDir.path}/pty_ssh_bridge.py');
    _ensureDirsAndBridge();
  }

  void _ensureDirsAndBridge() {
    try {
      keysDir.createSync(recursive: true);
      runDir.createSync(recursive: true);
      scriptsDir.createSync(recursive: true);
      Process.runSync('chmod', ['700', keysDir.path]);
      Process.runSync('chmod', ['700', runDir.path]);
      Process.runSync('chmod', ['700', scriptsDir.path]);

      // Encrypt any legacy unencrypted .pem files in keysDir and remove plaintext
      for (final entity in keysDir.listSync().whereType<File>()) {
        if (entity.path.endsWith('.pem')) {
          final encFile = File('${entity.path}.enc');
          final raw = entity.readAsStringSync();
          vault.writeEncryptedTextFile(encFile, raw);
          entity.deleteSync();
        }
      }

      // Clean up any stale askpass_* scripts from previous sessions
      for (final entity in scriptsDir.listSync().whereType<File>()) {
        final name = entity.path.split('/').last;
        if (name.startsWith('askpass_')) {
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }

      ptyBridgeScript.writeAsStringSync(_pythonPtyBridgeCode);
      Process.runSync('chmod', ['700', ptyBridgeScript.path]);
    } catch (_) {}
  }

  String _findPuttygenBinary() {
    final appdir = Platform.environment['APPDIR'] ?? '';
    if (appdir.isNotEmpty) {
      final bundled = '$appdir/usr/bin/puttygen';
      if (File(bundled).existsSync()) return bundled;
    }
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final candidate = '$exeDir/puttygen';
      if (File(candidate).existsSync()) return candidate;
    } catch (_) {}
    return 'puttygen';
  }

  bool _isPrivateKeyFile(String rawPath) {
    if (rawPath.isEmpty || !File(rawPath).existsSync()) return false;
    final lower = rawPath.toLowerCase();
    if (lower.endsWith('.ppk') ||
        lower.endsWith('.pem') ||
        lower.endsWith('.key')) {
      return true;
    }
    try {
      final firstLine = File(rawPath).readAsLinesSync().firstOrNull ?? '';
      if (firstLine.startsWith('PuTTY-User-Key-File') ||
          firstLine.contains('PRIVATE KEY')) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Converts or imports a private key, storing it encrypted at rest (`*.pem.enc`) in `keysDir`
  /// and returning a temporary `0600` file in `runDir` for active SSH/SFTP usage.
  Future<String?> _convertOrCopyKeyFile(
    String rawPath,
    String hostId,
    String tag,
    String secret,
  ) async {
    final encryptedCacheFile =
        File('${keysDir.path}/converted_${hostId}_$tag.pem.enc');
    final runtimeKeyFile = File('${runDir.path}/active_${hostId}_$tag.pem');

    if (rawPath.isNotEmpty && File(rawPath).existsSync()) {
      String firstLine = '';
      try {
        firstLine = File(rawPath).readAsLinesSync().firstOrNull ?? '';
      } catch (_) {}

      if (rawPath.toLowerCase().endsWith('.ppk') ||
          firstLine.startsWith('PuTTY-User-Key-File')) {
        final tempConverted =
            File('${runDir.path}/tmp_conv_${hostId}_$tag.pem');
        final puttygen = _findPuttygenBinary();
        final cleanEnv = Map<String, String>.from(Platform.environment)
          ..remove('LD_LIBRARY_PATH')
          ..remove('PYTHONHOME')
          ..remove('PYTHONPATH');
        cleanEnv['PPK_SECRET'] = secret;

        const pyConvert = r'''
import pty, os, sys, select

puttygen_bin = sys.argv[1]
src_ppk = sys.argv[2]
dst_pem = sys.argv[3]
secret = os.environ.get("PPK_SECRET", "")

pid, fd = pty.fork()
if pid == 0:
    os.execvp(puttygen_bin, [puttygen_bin, src_ppk, "-O", "private-openssh", "-o", dst_pem])
else:
    buf = b""
    sent = False
    while True:
        r, _, _ = select.select([fd], [], [], 4.0)
        if not r:
            break
        try:
            data = os.read(fd, 1024)
            if not data:
                break
            buf += data
            if not sent and b"passphrase" in buf.lower():
                os.write(fd, (secret + "\n").encode("utf-8"))
                sent = True
                buf = b""
        except OSError:
            break
    _, status = os.waitpid(pid, 0)
    sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
''';

        final res = await Process.run(
          'python3',
          ['-c', pyConvert, puttygen, rawPath, tempConverted.path],
          environment: cleanEnv,
        );
        if (res.exitCode == 0 && tempConverted.existsSync()) {
          final pemContent = tempConverted.readAsStringSync();
          try {
            tempConverted.deleteSync();
          } catch (_) {}
          // Save encrypted at rest in keysDir
          vault.writeEncryptedTextFile(encryptedCacheFile, pemContent);
          // Materialize 0600 runtime key in runDir
          runtimeKeyFile.writeAsStringSync(pemContent);
          Process.runSync('chmod', ['600', runtimeKeyFile.path]);
          return runtimeKeyFile.path;
        }
      } else {
        final rawPem = File(rawPath).readAsStringSync();
        vault.writeEncryptedTextFile(encryptedCacheFile, rawPem);
        runtimeKeyFile.writeAsStringSync(rawPem);
        Process.runSync('chmod', ['600', runtimeKeyFile.path]);
        return runtimeKeyFile.path;
      }
    }

    // Fallback: if encrypted key already exists in vault, decrypt into runDir
    if (encryptedCacheFile.existsSync()) {
      final pemContent = vault.readEncryptedTextFile(encryptedCacheFile);
      if (pemContent != null && pemContent.isNotEmpty) {
        runtimeKeyFile.writeAsStringSync(pemContent);
        Process.runSync('chmod', ['600', runtimeKeyFile.path]);
        return runtimeKeyFile.path;
      }
    }

    return null;
  }

  /// Prepares all configured identity keys (Key, SSH ID, FIDO2, or Private Key inside Certificate)
  Future<List<String>> prepareIdentityKeyFiles(SshHostConfig host) async {
    final files = <String>[];
    final secret =
        host.passphrase.isNotEmpty ? host.passphrase : host.password;

    // 1. Key (Chave Privada)
    if (host.enabledExtras.contains('privateKey')) {
      if (host.privateKeyContent.trim().isNotEmpty) {
        final content = host.privateKeyContent.trim();
        if (content.startsWith('PuTTY-User-Key-File')) {
          final tempPpk = File('${runDir.path}/tmp_pasted_${host.id}.ppk');
          tempPpk.writeAsStringSync('$content\n');
          final k = await _convertOrCopyKeyFile(
            tempPpk.path,
            host.id,
            'pasted_ppk',
            secret,
          );
          try {
            if (tempPpk.existsSync()) tempPpk.deleteSync();
          } catch (_) {}
          if (k != null) files.add(k);
        } else {
          final outKey = File('${runDir.path}/pasted_${host.id}.pem');
          String outContent = content;
          if (!outContent.endsWith('\n')) outContent += '\n';
          outKey.writeAsStringSync(outContent);
          Process.runSync('chmod', ['600', outKey.path]);
          files.add(outKey.path);
        }
      } else if (host.privateKeyPath.trim().isNotEmpty) {
        final k = await _convertOrCopyKeyFile(
          host.privateKeyPath.trim(),
          host.id,
          'pk',
          secret,
        );
        if (k != null) files.add(k);
      }
    }

    // 2. SSH ID (Passkeys for SSH)
    if (host.enabledExtras.contains('sshId') &&
        host.sshId.trim().isNotEmpty) {
      final k = await _convertOrCopyKeyFile(
        host.sshId.trim(),
        host.id,
        'sshid',
        secret,
      );
      if (k != null) files.add(k);
    }

    // 3. Certificate field if user selected a .ppk / .pem private key there
    if (host.enabledExtras.contains('certificate') &&
        host.certificatePath.trim().isNotEmpty &&
        _isPrivateKeyFile(host.certificatePath.trim())) {
      final k = await _convertOrCopyKeyFile(
        host.certificatePath.trim(),
        host.id,
        'certpk',
        secret,
      );
      if (k != null) files.add(k);
    }

    // 4. FIDO2 (Security Key)
    if (host.enabledExtras.contains('fido2') &&
        host.fido2KeyPath.trim().isNotEmpty) {
      if (File(host.fido2KeyPath.trim()).existsSync()) {
        files.add(host.fido2KeyPath.trim());
      }
    }

    return files;
  }

  /// Creates temporary SSH_ASKPASS script for password or key passphrase
  File? createAskPassScript(SshHostConfig host) {
    String secret = '';
    if (host.passphrase.isNotEmpty) {
      secret = host.passphrase;
    } else if (host.password.isNotEmpty) {
      secret = host.password;
    }
    if (secret.isEmpty) return null;

    final askFile = File(
        '${scriptsDir.path}/askpass_${host.id}_${DateTime.now().microsecondsSinceEpoch}.sh');
    final escaped = secret.replaceAll("'", r"'\''");
    askFile.writeAsStringSync('#!/bin/sh\nprintf \'%s\\n\' \'$escaped\'\n');
    Process.runSync('chmod', ['700', askFile.path]);
    return askFile;
  }

  Future<List<String>> buildCommonSshOptions(SshHostConfig host) async {
    final opts = <String>[
      '-o',
      'StrictHostKeyChecking=accept-new',
      '-o',
      'ServerAliveInterval=${host.keepAliveInterval}',
      '-o',
      'ServerAliveCountMax=3',
    ];

    final keyPaths = await prepareIdentityKeyFiles(host);
    for (final kp in keyPaths) {
      opts.addAll(['-i', kp]);
    }

    if (host.enabledExtras.contains('certificate') &&
        host.certificatePath.trim().isNotEmpty &&
        !_isPrivateKeyFile(host.certificatePath.trim())) {
      opts.addAll(['-o', 'CertificateFile=${host.certificatePath.trim()}']);
    }

    if (host.enabledExtras.contains('fido2') &&
        host.fido2Provider.trim().isNotEmpty) {
      opts.addAll(['-o', 'SecurityKeyProvider=${host.fido2Provider.trim()}']);
    }

    if (host.proxyJump.trim().isNotEmpty) {
      opts.addAll(['-J', host.proxyJump.trim()]);
    }
    if (host.localForward.trim().isNotEmpty) {
      opts.addAll(['-L', host.localForward.trim()]);
    }
    if (host.remoteForward.trim().isNotEmpty) {
      opts.addAll(['-R', host.remoteForward.trim()]);
    }
    if (host.x11Forwarding) {
      opts.add('-X');
    }
    if (host.compression) {
      opts.add('-C');
    }

    return opts;
  }

  // ==========================================================================
  // NATIVE SFTP SUBSYSTEM PROTOCOL EXECUTION (NO SHELL / NO BASH INTERPOLATION)
  // ==========================================================================

  /// Sanitizes and quotes a path argument for the SFTP protocol batch parser.
  /// Rejects control characters (\0, \n, \r) to prevent batch command injection,
  /// and escapes backslashes and double quotes.
  String _quoteSftpPath(String rawPath) {
    if (rawPath.contains('\u0000') ||
        rawPath.contains('\n') ||
        rawPath.contains('\r')) {
      throw const FormatException(
          'Caminho contém caracteres de controle inválidos.');
    }
    final escaped =
        rawPath.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  /// Executes native SFTP protocol commands over `/usr/bin/sftp -b -`
  /// (using the SSH `sftp` subsystem directly without invoking any remote shell).
  Future<ProcessResult> _runSftpBatch(
    SshHostConfig host,
    List<String> sftpCommands,
  ) async {
    final commonOpts = await buildCommonSshOptions(host);
    final askPass = createAskPassScript(host);

    final cleanEnv = Map<String, String>.from(Platform.environment)
      ..remove('LD_LIBRARY_PATH')
      ..remove('PYTHONHOME')
      ..remove('PYTHONPATH');

    if (askPass != null) {
      cleanEnv['SSH_ASKPASS'] = askPass.path;
      cleanEnv['SSH_ASKPASS_REQUIRE'] = 'force';
      cleanEnv['DISPLAY'] = cleanEnv['DISPLAY'] ?? ':0';
    }

    final batchFile = File(
        '${runDir.path}/sftp_batch_${host.id}_${DateTime.now().microsecondsSinceEpoch}.txt');
    try {
      batchFile.writeAsStringSync('${sftpCommands.join('\n')}\n');
      Process.runSync('chmod', ['600', batchFile.path]);

      final args = [
        '-P',
        host.port.toString(),
        '-o',
        'ConnectTimeout=10',
        // `sftp -b` força BatchMode=yes, o que desativa SSH_ASKPASS (senha/passphrase).
        // O ssh usa o primeiro valor definido, então este -o precisa vir antes do -b.
        '-o',
        'BatchMode=no',
        ...commonOpts,
        '-b',
        batchFile.path,
        '${host.username}@${host.address}',
      ];
      return await Process.run('sftp', args, environment: cleanEnv);
    } finally {
      try {
        if (batchFile.existsSync()) batchFile.deleteSync();
      } catch (_) {}
      try {
        if (askPass != null && askPass.existsSync()) askPass.deleteSync();
      } catch (_) {}
    }
  }

  /// Lists a remote directory using the native SFTP subsystem (`cd`, `pwd`, `ls -la`).
  /// Zero shell commands (`sh`/`bash`) are executed on the remote server.
  Future<(String resolvedPath, List<SftpRemoteEntry> entries, String? error)>
      listRemoteDirectory(SshHostConfig host, String targetPath) async {
    String quotedTarget;
    try {
      quotedTarget = _quoteSftpPath(targetPath.isEmpty ? '.' : targetPath);
    } catch (e) {
      return (targetPath, <SftpRemoteEntry>[], e.toString());
    }

    final res = await _runSftpBatch(host, [
      'cd -- $quotedTarget',
      'pwd',
      'ls -la',
    ]);

    if (res.exitCode != 0) {
      return (
        targetPath,
        <SftpRemoteEntry>[],
        res.stderr.toString().trim().isNotEmpty
            ? res.stderr.toString().trim()
            : 'Falha SFTP ao listar diretório (cód. ${res.exitCode})'
      );
    }

    final lines = const LineSplitter().convert(res.stdout.toString());
    String resolvedPwd = targetPath;
    final entries = <SftpRemoteEntry>[];

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('sftp>')) continue;

      if (line.startsWith('Remote working directory:')) {
        resolvedPwd =
            line.substring('Remote working directory:'.length).trim();
        continue;
      }

      // Parse standard SFTP `ls -la` entry line (starts with permission bits like drwxr-xr-x or -rw-r--r--)
      if (!RegExp(r'^[dlcbps-][rwxstST-]{9}').hasMatch(line)) {
        continue;
      }

      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 9) continue;

      final perms = parts[0];
      final size = parts[4];
      final dateStr = '${parts[5]} ${parts[6]} ${parts[7]}';
      String name = parts.sublist(8).join(' ');

      // SFTP `ls -la` prefixes paths if listing a directory or shows basenames after `cd`
      if (name.contains('/')) {
        name = name.split('/').last;
      }
      if (name == '.' || name == '..' || name.isEmpty) continue;

      entries.add(
        SftpRemoteEntry(
          name: name,
          permissions: perms,
          size: _formatBytes(int.tryParse(size) ?? 0),
          date: dateStr,
          isDirectory: perms.startsWith('d'),
          isSymlink: perms.startsWith('l'),
        ),
      );
    }

    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return (resolvedPwd, entries, null);
  }

  /// Creates a remote directory using native SFTP protocol (`mkdir -- "path"`).
  Future<(bool ok, String? error)> createRemoteDirectory(
    SshHostConfig host,
    String remoteDirPath,
  ) async {
    try {
      final quoted = _quoteSftpPath(remoteDirPath);
      final res = await _runSftpBatch(host, ['mkdir -- $quoted']);
      if (res.exitCode == 0) {
        return (true, null);
      }
      return (false, res.stderr.toString().trim());
    } catch (e) {
      return (false, e.toString());
    }
  }

  /// Deletes a remote file or directory using native SFTP protocol (`rm` / `rmdir`)
  /// without ever invoking a remote shell (`rm -rf` is never used).
  Future<(bool ok, String? error)> deleteRemoteEntry(
    SshHostConfig host,
    String remotePath, {
    required bool isDirectory,
  }) async {
    try {
      if (!isDirectory) {
        final quoted = _quoteSftpPath(remotePath);
        final res = await _runSftpBatch(host, ['rm -- $quoted']);
        return (
          res.exitCode == 0,
          res.exitCode == 0 ? null : res.stderr.toString().trim()
        );
      }

      // Recursive SFTP directory deletion via SFTP protocol
      Future<void> collectAndDelete(String dirPath) async {
        final (_, children, err) = await listRemoteDirectory(host, dirPath);
        if (err != null) return;

        final fileDeleteCmds = <String>[];
        for (final child in children) {
          final childPath = dirPath.endsWith('/')
              ? '$dirPath${child.name}'
              : '$dirPath/${child.name}';
          if (child.isDirectory && !child.isSymlink) {
            await collectAndDelete(childPath);
          } else {
            fileDeleteCmds.add('rm -- ${_quoteSftpPath(childPath)}');
          }
        }
        if (fileDeleteCmds.isNotEmpty) {
          await _runSftpBatch(host, fileDeleteCmds);
        }
        await _runSftpBatch(host, ['rmdir -- ${_quoteSftpPath(dirPath)}']);
      }

      await collectAndDelete(remotePath);
      return (true, null);
    } catch (e) {
      return (false, e.toString());
    }
  }

  /// Transfers a file or directory using the native SFTP protocol (`put -r` / `get -r`).
  Future<(bool ok, String message)> transferFile({
    required SshHostConfig host,
    required String localPath,
    required String remotePath,
    required bool isUpload,
  }) async {
    try {
      final quotedLocal = _quoteSftpPath(localPath);
      final quotedRemote = _quoteSftpPath(remotePath);
      final cmd = isUpload
          ? 'put -r -- $quotedLocal $quotedRemote'
          : 'get -r -- $quotedRemote $quotedLocal';

      final res = await _runSftpBatch(host, [cmd]);
      if (res.exitCode == 0) {
        return (
          true,
          isUpload
              ? 'Upload SFTP concluído com sucesso!'
              : 'Download SFTP concluído em: $localPath'
        );
      }
      return (false, res.stderr.toString().trim());
    } catch (e) {
      return (false, e.toString());
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static const String _pythonPtyBridgeCode = r'''#!/usr/bin/env python3
import os
import sys
import pty
import json
import fcntl
import errno
import signal
import select
import struct
import termios

def set_winsize(fd, rows, cols):
    try:
        winsize = struct.pack("HHHH", rows, cols, 0, 0)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)
    except Exception:
        pass

def main():
    cmd = sys.argv[1:]
    if not cmd:
        sys.exit(1)

    pid, master_fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execvp(cmd[0], cmd)
        sys.exit(1)

    set_winsize(master_fd, 28, 100)
    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()

    buf = b""
    try:
        while True:
            rlist, _, _ = select.select([master_fd, stdin_fd], [], [])
            if master_fd in rlist:
                try:
                    data = os.read(master_fd, 8192)
                    if not data:
                        break
                    os.write(stdout_fd, data)
                except OSError as e:
                    if e.errno == errno.EIO:
                        break
                    raise

            if stdin_fd in rlist:
                chunk = os.read(stdin_fd, 4096)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if not line:
                        continue
                    try:
                        msg = json.loads(line.decode("utf-8", errors="ignore"))
                        t = msg.get("t")
                        if t == "d":
                            raw = msg.get("d", "").encode("utf-8")
                            os.write(master_fd, raw)
                        elif t == "r":
                            rows = int(msg.get("rows", 24))
                            cols = int(msg.get("cols", 80))
                            set_winsize(master_fd, rows, cols)
                    except Exception:
                        pass
    except Exception:
        pass
    finally:
        exit_code = 0
        try:
            _, status = os.waitpid(pid, os.WNOHANG)
            if status == 0:
                os.kill(pid, signal.SIGTERM)
                _, status = os.waitpid(pid, 0)
            if os.WIFEXITED(status):
                exit_code = os.WEXITSTATUS(status)
        except Exception:
            pass
        sys.exit(exit_code)

if __name__ == "__main__":
    main()
''';
}

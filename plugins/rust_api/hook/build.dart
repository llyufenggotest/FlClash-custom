import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.userDefines['build_assets'] == false) {
      stdout.writeln('Skipping the Rust build: user-define build_assets=false');
      return;
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: _bindgenEnvironment(input),
    ).run(input: input, output: output);
  });
}

// rquickjs runs bindgen on Android, which must load the NDK's libclang; Linux
// NDKs before r26 keep it under lib64, later ones and every macOS NDK under lib.
Map<String, String> _bindgenEnvironment(BuildInput input) {
  if (!input.config.buildCodeAssets) return const {};
  final code = input.config.code;
  if (code.targetOS == OS.iOS) {
    final sdk = code.iOS.targetSdk == IOSSdk.iPhoneOS
        ? 'iphoneos'
        : 'iphonesimulator';
    String xcrun(List<String> args) {
      final result = Process.runSync('xcrun', ['--sdk', sdk, ...args]);
      if (result.exitCode != 0) {
        throw ProcessException(
          'xcrun',
          args,
          '${result.stderr}',
          result.exitCode,
        );
      }
      return (result.stdout as String).trim();
    }

    final sdkPath = xcrun(['--show-sdk-path']);
    final clang = xcrun(['--find', 'clang']);
    return {
      'LIBCLANG_PATH': '${File(clang).parent.parent.path}/lib',
      'BINDGEN_EXTRA_CLANG_ARGS': '-isysroot "$sdkPath"',
      'IPHONEOS_DEPLOYMENT_TARGET': '${code.iOS.targetVersion}.0',
    };
  }
  if (code.targetOS != OS.android) {
    return const {};
  }
  final compiler = input.config.code.cCompiler?.compiler;
  if (compiler == null) {
    return const {};
  }
  final llvmRoot = File.fromUri(compiler).parent.parent;
  for (final name in const ['lib', 'lib64', 'bin']) {
    final directory = Directory(
      '${llvmRoot.path}${Platform.pathSeparator}$name',
    );
    if (_containsLibclang(directory)) {
      return {'LIBCLANG_PATH': directory.path};
    }
  }

  // Flutter can select an older SDK NDK for the compiler even when CI installs
  // the project NDK. Bindgen only needs a host libclang, so fall back to the
  // runner's LLVM installation instead of coupling it to that compiler NDK.
  ProcessResult? llvmConfig;
  try {
    llvmConfig = Process.runSync('llvm-config', ['--libdir']);
  } on ProcessException {
    llvmConfig = null;
  }
  if (llvmConfig?.exitCode == 0) {
    final directory = Directory('${llvmConfig!.stdout}'.trim());
    if (_containsLibclang(directory)) {
      return {'LIBCLANG_PATH': directory.path};
    }
  }
  for (final root in const ['/usr/lib/llvm-20/lib', '/usr/lib/llvm-19/lib']) {
    final directory = Directory(root);
    if (_containsLibclang(directory)) {
      return {'LIBCLANG_PATH': directory.path};
    }
  }
  throw StateError(
    'No usable libclang under ${llvmRoot.path} or the host LLVM installation; '
    'bindgen cannot generate rquickjs bindings',
  );
}

bool _containsLibclang(Directory directory) {
  return directory.existsSync() && directory.listSync().any(_isLibclang);
}

bool _isLibclang(FileSystemEntity entity) {
  return entity.path.split(Platform.pathSeparator).last.startsWith('libclang.');
}

import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<String> _modelRoot() async {
  final dir = await getApplicationSupportDirectory();
  final root = p.join(dir.path, 'models');
  await Directory(root).create(recursive: true);
  return root;
}

Future<String> copyAssetFile(String assetPath) async {
  final root = await _modelRoot();
  final relative = assetPath.startsWith('assets/')
      ? assetPath.substring('assets/'.length)
      : assetPath;
  final dstPath = p.join(root, relative);
  final dstFile = File(dstPath);
  if (await dstFile.exists()) {
    return dstPath;
  }
  await dstFile.parent.create(recursive: true);
  final data = await rootBundle.load(assetPath);
  await dstFile.writeAsBytes(data.buffer.asUint8List(), flush: true);
  return dstPath;
}

Future<List<String>> copyAssetDirectory(String assetPrefix) async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final assets = manifest.listAssets()
      .where((key) => key.startsWith(assetPrefix))
      .toList(growable: false);

  final copied = <String>[];
  for (final asset in assets) {
    final dst = await copyAssetFile(asset);
    copied.add(dst);
  }
  return copied;
}

Future<String> localDirForAssetPrefix(String assetPrefix) async {
  final root = await _modelRoot();
  final relative = assetPrefix.startsWith('assets/')
      ? assetPrefix.substring('assets/'.length)
      : assetPrefix;
  return p.join(root, relative);
}

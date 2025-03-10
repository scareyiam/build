// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:convert';

import 'package:build/build.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'assets.dart';
import 'in_memory_reader.dart';
import 'in_memory_writer.dart';
import 'multi_asset_reader.dart';
import 'resolve_source.dart';

AssetId _passThrough(AssetId id) => id;

/// Validates that [actualAssets] matches the expected [outputs].
///
/// The keys in [outputs] should be serialized [AssetId]s in the form
/// `'package|path'`. The values should match the expected content for the
/// written asset and may be a String (for `writeAsString`), a `List<int>` (for
/// `writeAsBytes`) or a [Matcher] for a String or bytes.
///
/// [actualAssets] are the IDs that were recorded as written during the build.
///
/// Assets are checked against those that were written to [writer]. If other
/// assets were written through the writer, but not as part of the build
/// process, they will be ignored. Only the IDs in [actualAssets] are checked.
///
/// If assets are written to a location that does not match their logical
/// association to a package pass [mapAssetIds] to translate from the logical
/// location to the actual written location.
void checkOutputs(
    Map<String, /*List<int>|String|Matcher<String|List<int>>*/ dynamic> outputs,
    Iterable<AssetId> actualAssets,
    RecordingAssetWriter writer,
    {AssetId mapAssetIds(AssetId id) = _passThrough}) {
  var modifiableActualAssets = Set.from(actualAssets);
  if (outputs != null) {
    outputs.forEach((serializedId, contentsMatcher) {
      assert(contentsMatcher is String ||
          contentsMatcher is List<int> ||
          contentsMatcher is Matcher);

      var assetId = makeAssetId(serializedId);

      // Check that the asset was produced.
      expect(modifiableActualAssets, contains(assetId),
          reason: 'Builder failed to write asset $assetId');
      modifiableActualAssets.remove(assetId);
      var actual = writer.assets[mapAssetIds(assetId)];
      Object expected;
      if (contentsMatcher is String) {
        expected = utf8.decode(actual);
      } else if (contentsMatcher is List<int>) {
        expected = actual;
      } else if (contentsMatcher is Matcher) {
        expected = actual;
      } else {
        throw ArgumentError('Expected values for `outputs` to be of type '
            '`String`, `List<int>`, or `Matcher`, but got `$contentsMatcher`.');
      }
      expect(expected, contentsMatcher,
          reason: 'Unexpected content for $assetId in result.outputs.');
    });
    // Check that no extra assets were produced.
    expect(modifiableActualAssets, isEmpty,
        reason:
            'Unexpected outputs found `$actualAssets`. Only expected $outputs');
  }
}

/// Runs [builder] in a test environment.
///
/// The test environment supplies in-memory build [sourceAssets] to the builders
/// under test. [outputs] may be optionally provided to verify that the builders
/// produce the expected output. If [outputs] is omitted the only validation
/// this method provides is that the build did not `throw`.
///
/// Either [generateFor] or the [isInput] callback can specify which assets
/// should be given as inputs to the builder. These can be omitted if every
/// asset in [sourceAssets] should be considered an input. [generateFor] is
/// ignored if both [isInput] and [generateFor] are provided.
///
/// The keys in [sourceAssets] and [outputs] are paths to file assets and the
/// values are file contents. The paths must use the following format:
///
///     PACKAGE_NAME|PATH_WITHIN_PACKAGE
///
/// Where `PACKAGE_NAME` is the name of the package, and `PATH_WITHIN_PACKAGE`
/// is the path to a file relative to the package. `PATH_WITHIN_PACKAGE` must
/// include `lib`, `web`, `bin` or `test`. Example: "myapp|lib/utils.dart".
///
/// If a [reader] is provided, then any asset not in [sourceAssets] will be
/// read from the provided reader. This allows you to more easily provide
/// sources of entire packages to the test, instead of mocking them out, for
/// example, this exposes all assets available to the test itself:
///
///
/// ```dart
/// testBuilder(yourBuilder, {}/* test assets here */,
///     reader: await PackageAssetReader.currentIsolate());
/// ```
///
/// Callers may optionally provide a [writer] to stub different behavior or do
/// more complex validation than what is possible with [outputs].
///
/// Callers may optionally provide an [onLog] callback to do validaiton on the
/// logging output of the builder.
Future testBuilder(
    Builder builder, Map<String, /*String|List<int>*/ dynamic> sourceAssets,
    {Set<String> generateFor,
    bool isInput(String assetId),
    String rootPackage,
    MultiPackageAssetReader reader,
    RecordingAssetWriter writer,
    Map<String, /*String|List<int>|Matcher<String|List<int>>*/ dynamic> outputs,
    void onLog(LogRecord log)}) async {
  writer ??= InMemoryAssetWriter();
  final inMemoryReader = InMemoryAssetReader(rootPackage: rootPackage);
  if (reader != null) {
    reader = MultiAssetReader([inMemoryReader, reader]);
  } else {
    reader = inMemoryReader;
  }

  var inputIds = <AssetId>[];
  sourceAssets.forEach((serializedId, contents) {
    var id = makeAssetId(serializedId);
    if (contents is String) {
      inMemoryReader.cacheStringAsset(id, contents);
    } else if (contents is List<int>) {
      inMemoryReader.cacheBytesAsset(id, contents);
    }
    inputIds.add(id);
  });

  var allPackages = inMemoryReader.assets.keys.map((a) => a.package).toSet();
  for (var pkg in allPackages) {
    for (var dir in const ['lib', 'web', 'test']) {
      var asset = AssetId(pkg, '$dir/\$$dir\$');
      inputIds.add(asset);
    }
  }

  isInput ??= generateFor?.contains ?? (_) => true;
  inputIds = inputIds.where((id) => isInput('$id')).toList();

  var writerSpy = AssetWriterSpy(writer);
  var logger = Logger('testBuilder');
  var logSubscription = logger.onRecord.listen(onLog);
  await runBuilder(builder, inputIds, reader, writerSpy, defaultResolvers,
      logger: logger);
  await logSubscription.cancel();
  var actualOutputs = writerSpy.assetsWritten;
  checkOutputs(outputs, actualOutputs, writer);
}

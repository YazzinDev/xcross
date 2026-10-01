// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import 'asset_catalog.dart';
import 'asset_catalog_fixtures.dart';

Future<void> main(List<String> arguments) async {
  final options = (ArgParser()..addOption('output')).parse(arguments);
  if (options.rest.length != 2 ||
      !{'fixture', 'audit'}.contains(options.rest[0])) {
    throw ArgumentError(
      'Usage: asset_catalog_audit.dart fixture|audit <path> [--output <file>]',
    );
  }
  final result = options.rest[0] == 'fixture'
      ? await writeAssetCatalogFixtures(options.rest[1])
      : AssetCatalog(await File(options.rest[1]).readAsBytes()).audit();
  final encoded = const JsonEncoder.withIndent('  ').convert(result);
  final output = options.option('output');
  if (output == null) {
    stdout.writeln(encoded);
  } else {
    await File(output).writeAsString('$encoded\n');
  }
  if (options.rest[0] == 'audit' &&
      (result['lookupMaskErrors']! as List).isNotEmpty) {
    exitCode = 1;
  }
}

// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/lsp_protocol/protocol_generated.dart';
import 'package:analysis_server/lsp_protocol/protocol_special.dart';
import 'package:analysis_server/protocol/protocol_generated.dart'
    hide AnalysisGetNavigationParams;
import 'package:analysis_server/src/domains/analysis/macro_files.dart';
import 'package:analysis_server/src/lsp/handlers/handlers.dart';
import 'package:analysis_server/src/lsp/lsp_analysis_server.dart';
import 'package:analysis_server/src/lsp/mapping.dart';
import 'package:analysis_server/src/plugin/result_merger.dart';
import 'package:analysis_server/src/protocol_server.dart' show NavigationTarget;
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer_plugin/protocol/protocol_generated.dart' as plugin;
import 'package:analyzer_plugin/src/utilities/navigation/navigation.dart';
import 'package:analyzer_plugin/utilities/analyzer_converter.dart';
import 'package:analyzer_plugin/utilities/navigation/navigation_dart.dart';
import 'package:collection/collection.dart';

class DefinitionHandler extends MessageHandler<TextDocumentPositionParams,
        Either2<List<Location>, List<LocationLink>>>
    with LspPluginRequestHandlerMixin {
  DefinitionHandler(LspAnalysisServer server) : super(server);
  @override
  Method get handlesMessage => Method.textDocument_definition;

  @override
  LspJsonHandler<TextDocumentPositionParams> get jsonHandler =>
      TextDocumentPositionParams.jsonHandler;

  Future<List<AnalysisNavigationParams>> getPluginResults(
    String path,
    int offset,
  ) async {
    // LSP requests must be converted to DAS-protocol requests for compatibility
    // with plugins.
    final requestParams = plugin.AnalysisGetNavigationParams(path, offset, 0);
    final responses = await requestFromPlugins(path, requestParams);

    return responses
        .map((response) =>
            plugin.AnalysisGetNavigationResult.fromResponse(response))
        .map((result) => AnalysisNavigationParams(
            path, result.regions, result.targets, result.files))
        .toList();
  }

  Future<AnalysisNavigationParams> getServerResult(
      bool supportsLocationLink, String path, int offset) async {
    final collector =
        NavigationCollectorImpl(collectCodeLocations: supportsLocationLink);

    final result = await server.getResolvedUnit(path);
    final unit = result?.unit;
    if (result?.state == ResultState.VALID && unit != null) {
      computeDartNavigation(server.resourceProvider, collector, unit, offset, 0,
          analyzerConverter: AnalyzerConverter(
              locationProvider: MacroElementLocationProvider(
                  MacroFiles(server.resourceProvider))));
      collector.createRegions();
    }

    return AnalysisNavigationParams(
        path, collector.regions, collector.targets, collector.files);
  }

  @override
  Future<ErrorOr<Either2<List<Location>, List<LocationLink>>>> handle(
      TextDocumentPositionParams params, CancellationToken token) async {
    final clientCapabilities = server.clientCapabilities;
    if (clientCapabilities == null) {
      // This should not happen unless a client misbehaves.
      return error(ErrorCodes.ServerNotInitialized,
          'Requests not before server is initilized');
    }

    final supportsLocationLink = clientCapabilities.definitionLocationLink;

    final pos = params.position;
    final path = pathOfDoc(params.textDocument);

    return path.mapResult((path) async {
      final lineInfo = server.getLineInfo(path);
      // If there is no lineInfo, the request cannot be translated from LSP line/col
      // to server offset/length.
      if (lineInfo == null) {
        return success(
          Either2<List<Location>, List<LocationLink>>.t1(const []),
        );
      }

      final offset = toOffset(lineInfo, pos);

      return offset.mapResult((offset) async {
        final allResults = [
          await getServerResult(supportsLocationLink, path, offset),
          ...await getPluginResults(path, offset),
        ];

        final merger = ResultMerger();
        final mergedResults = merger.mergeNavigation(allResults);
        final mergedTargets = mergedResults?.targets ?? [];

        if (mergedResults == null) {
          return success(
            Either2<List<Location>, List<LocationLink>>.t1(const []),
          );
        }

        // Convert and filter the results using the correct type of Location class
        // depending on the client capabilities.
        if (supportsLocationLink) {
          final convertedResults = convert(
            mergedTargets,
            (NavigationTarget target) =>
                _toLocationLink(mergedResults, lineInfo, target),
          ).whereNotNull().toList();

          final results = _filterResults(
            convertedResults,
            params.textDocument.uri,
            pos.line,
            (LocationLink element) => element.targetUri,
            (LocationLink element) => element.targetSelectionRange,
          );

          return success(
            Either2<List<Location>, List<LocationLink>>.t2(results),
          );
        } else {
          final convertedResults = convert(
            mergedTargets,
            (NavigationTarget target) => _toLocation(mergedResults, target),
          ).whereNotNull().toList();

          final results = _filterResults(
            convertedResults,
            params.textDocument.uri,
            pos.line,
            (Location element) => element.uri,
            (Location element) => element.range,
          );

          return success(
            Either2<List<Location>, List<LocationLink>>.t1(results),
          );
        }
      });
    });
  }

  /// Helper that selects the correct results (filtering out at the same
  /// line/location) generically, handling either type of Location class.
  List<T> _filterResults<T>(
    List<T> results,
    String sourceUri,
    int sourceLineNumber,
    String Function(T) uriSelector,
    Range Function(T) rangeSelector,
  ) {
    // If we fetch navigation on a keyword like `var`, the results will include
    // both the definition and also the variable name. This will cause the editor
    // to show the user both options unnecessarily (the variable name is always
    // adjacent to the var keyword, so providing navigation to it is not useful).
    // To prevent this, filter the list to only those on different lines (or
    // different files).
    final otherResults = results
        .where((element) =>
            uriSelector(element) != sourceUri ||
            rangeSelector(element).start.line != sourceLineNumber)
        .toList();

    return otherResults.isNotEmpty ? otherResults : results;
  }

  Location? _toLocation(
      AnalysisNavigationParams mergedResults, NavigationTarget target) {
    final targetFilePath = mergedResults.files[target.fileIndex];
    final targetLineInfo = server.getLineInfo(targetFilePath);
    return targetLineInfo != null
        ? navigationTargetToLocation(targetFilePath, target, targetLineInfo)
        : null;
  }

  LocationLink? _toLocationLink(AnalysisNavigationParams mergedResults,
      LineInfo sourceLineInfo, NavigationTarget target) {
    final region = mergedResults.regions.first;
    final targetFilePath = mergedResults.files[target.fileIndex];
    final targetLineInfo = server.getLineInfo(targetFilePath);

    return targetLineInfo != null
        ? navigationTargetToLocationLink(
            region, sourceLineInfo, targetFilePath, target, targetLineInfo)
        : null;
  }
}

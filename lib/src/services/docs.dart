import 'dart:async';

import 'package:fuzzy/data/result.dart';
import 'package:fuzzy/fuzzy.dart';
import 'package:running_on_dart/running_on_dart.dart';
import 'package:running_on_dart/src/models/docs.dart';

final Map<String, PackageDocs> _cache = {};
DateTime? lastDocsUpdate;

/// Initialise the documentaion cache and schedule a cache update every [docsUpdateInterval].
void initDocsCache() {
  for (final package in docsPackages) {
    _cache[package] = PackageDocs(packageName: package);
  }

  _updateDocsCache();
  Timer.periodic(docsUpdateInterval, (timer) => _updateDocsCache());
}

Future<void> _updateDocsCache() async {
  await Future.wait(_cache.values.map((e) => e.update()));
  lastDocsUpdate = DateTime.now();
}

/// Get the documentation for a package.
///
/// The package must be included in [docsPackages], or an exception will be thrown.
FutureOr<PackageDocs> getPackageDocs(String packageName) => _cache[packageName]!;

/// Get all documentation entries across all packages.
Iterable<DocEntry> getAllEntries() => _cache.values.fold(Iterable.empty(), (previousValue, element) => previousValue.followedBy(element.elements));

/// Get a documentation entry by its qualified name. Returns `null` if no entry was found.
DocEntry? getByQualifiedName(String qualifiedName) => getAllEntries()
    // Cast to DocEntry? so we can return null in orElse
    .cast<DocEntry?>()
    .firstWhere((element) => element?.qualifiedName == qualifiedName, orElse: () => null);

/// Searches for a specific element across all documentation using fuzzy search.
Iterable<DocEntry> searchInDocs(String query) {
  List<Result<DocEntry>> results = Fuzzy<DocEntry>(
    getAllEntries().toList(),
    options: FuzzyOptions(
      keys: [
        WeightedKey(
          name: 'qualifiedName',
          getter: (entry) => entry.qualifiedName,
          weight: 1,
        ),
        WeightedKey(
          name: 'name',
          getter: (entry) => entry.name,
          weight: 2,
        ),
        WeightedKey(
          name: 'displayName',
          getter: (entry) => entry.displayName,
          weight: 3,
        ),
      ],
      // We perform our own sort later
      shouldSort: false,
    ),
  ).search(query);

  results.sort((a, b) {
    num getWeight(DocEntry entry) {
      if (entry.type == 'method' && (entry.name.startsWith('operator ') || entry.name == 'hashCode')) {
        // We don't want operators or hashCodes polluting our results
        return 10;
      }

      List<String> priorities = [
        'library',
        'class',
        'top-level constant',
        'top-level property',
        'function',
        'constant',
        'property',
        'method',
      ];

      if (priorities.contains(entry.type)) {
        // Offset by 1 so we don't get a weight of 0, which would be a perfect score
        return priorities.indexOf(entry.type) + 1;
      }

      return priorities.length + 1;
    }

    num aWeight = getWeight(a.item);
    num bWeight = getWeight(b.item);

    int result;

    if (a.score == 0 && b.score == 0) {
      result = aWeight.compareTo(bWeight);
    } else {
      result = (a.score * aWeight).compareTo(b.score * bWeight);
    }

    if (result == 0) {
      // If both elements had the same score, compare their libraries
      int aIndex = docsPackages.indexOf(a.item.packageName);
      int bIndex = docsPackages.indexOf(b.item.packageName);

      result = aIndex.compareTo(bIndex);
    }

    if (result == 0) {
      // If both elements still have the same score, sort alphabetically on their display name
      result = a.item.displayName.compareTo(b.item.displayName);
    }

    return result;
  });

  return results.map((result) => result.item);
}

/// Gets a documentation entry from a query string.
///
/// This first attempts to find the element by qualified name, then returns the most prevalent search result.
DocEntry? getByQuery(String query) =>
    getByQualifiedName(query) ??
    searchInDocs(query)

        // Cast to DocEntry? so we can return null in orElse
        .cast<DocEntry?>()
        // Return the top result, or `null` if the list is empty
        .firstWhere((element) => true, orElse: () => null);
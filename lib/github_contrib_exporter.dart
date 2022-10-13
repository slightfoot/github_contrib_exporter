import 'dart:io';

import 'package:csv/csv.dart';
import 'package:github/github.dart';
import 'package:http/http.dart';
import 'package:http/retry.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:intl/intl_standalone.dart';
import 'package:week_of_year/week_of_year.dart';

final csv = ListToCsvConverter();

Future<void> main(List<String> arguments) async {
  print('GitHub Contributor Data Exporter - by Simon Lightfoot - 13/10/2022');

  // Valid input
  if (arguments.length != 1 || !arguments[0].contains('/')) {
    stderr.writeln('Usage: ${Platform.script.pathSegments.last} <owner/repo>');
    exitCode = -1;
    return;
  }
  final ownerRepo = arguments[0];

  // Fetch Github authentication from process environment variables.
  // See. [COMMON_GITHUB_TOKEN_ENV_KEYS]
  final auth = findAuthenticationFromEnvironment();
  if (auth.isAnonymous) {
    stderr.writeln('GITHUB_TOKEN environment variable not set');
    exitCode = -1;
    return;
  }

  // Connect and fetch entries from GitHub, with backup logic for when
  // it accepts our request but is still processing it.
  late GitHub github;
  List<ContributorStatistics> stats;
  try {
    github = GitHub(
      auth: auth,
      client: RetryClient(
        Client(),
        when: (BaseResponse response) async {
          return (response.statusCode == HttpStatus.accepted ||
              response.statusCode == HttpStatus.gatewayTimeout);
        },
      ),
    );
    stats = await github.repositories.listContributorStats(RepositorySlug.full(ownerRepo));
  } finally {
    github.client.close();
  }

  // Output some overall stats
  final entries = stats.fold<int>(0, (prev, el) => prev + (el.weeks?.length ?? 0));
  print('Got ${stats.length} contributors with $entries entries total.');

  // Start building CSV rows with a header
  final rows = <List<String>>[
    [
      'Owner/Repo',
      'Username',
      'Date',
      'Week',
      'Additions',
      'Deletions',
      'Commits',
      'Total Commits',
    ]
  ];

  // Format date as short date
  Intl.defaultLocale = await findSystemLocale();
  await initializeDateFormatting();
  final dateFormatter = DateFormat.yMd();

  // Process each entry and add to rows
  print('Processing…');
  for (final stat in stats) {
    final weeks = stat.weeks;
    if (weeks == null) {
      continue;
    }
    final author = stat.author;
    if (author == null) {
      continue;
    }
    final total = (stat.total ?? 0).toString();
    for (final week in weeks) {
      final start = week.start;
      if (start == null) {
        continue;
      }
      final date = DateTime.fromMillisecondsSinceEpoch(start * 1000);
      rows.add([
        ownerRepo,
        author.login ?? '',
        dateFormatter.format(date),
        date.weekOfYear.toString(),
        (week.additions ?? 0).toString(),
        (week.deletions ?? 0).toString(),
        (week.commits ?? 0).toString(),
        total,
      ]);
    }
  }

  /// Save output rows to file as CSV.
  final csvFile = File('${ownerRepo.replaceAll('/', '_')}.csv');
  csvFile.writeAsStringSync(csv.convert(rows));
  print('Exported to ${csvFile.absolute.path}');
}

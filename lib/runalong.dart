/// Host-side recording and reporting for existing Flutter automation.
library;

export 'src/model.dart';
export 'src/run_service.dart' show RunService;
export 'src/reporting.dart'
    show buildReport, writeReports, regenerateReport, compareReports;

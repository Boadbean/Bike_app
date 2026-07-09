import '../models/bike_data.dart';

/// Source of live telemetry for the dashboard. The concrete implementation
/// ([HttpStatusBikeDataService]) polls the ESP32 firmware `/api/status`
/// endpoint; [BikeDataSource] owns whichever source is active and re-publishes
/// it on a stable stream.
abstract class BikeDataService {
  Stream<BikeData> get stream;

  void dispose();
}

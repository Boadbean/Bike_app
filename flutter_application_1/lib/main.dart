import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/bike_data_service.dart';
import 'services/ride_recorder.dart';
import 'services/ride_repository.dart';

void main() {
  runApp(const BikeAssistApp());
}

class BikeAssistApp extends StatefulWidget {
  const BikeAssistApp({super.key});

  @override
  State<BikeAssistApp> createState() => _BikeAssistAppState();
}

class _BikeAssistAppState extends State<BikeAssistApp> with WidgetsBindingObserver {
  late final BikeDataService _dataService = MockBikeDataService();
  late final RideRepository _repository = RideRepository();
  late final RideRecorder _recorder = RideRecorder(
    dataService: _dataService,
    repository: _repository,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _recorder.init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _recorder.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recorder.dispose();
    _dataService.dispose();
    _repository.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'bike-assist',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: HomeScreen(
        dataService: _dataService,
        repository: _repository,
        recorder: _recorder,
      ),
    );
  }
}

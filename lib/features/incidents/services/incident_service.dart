import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:permission_handler/permission_handler.dart';
import '../../../core/database/database_helper.dart';
import '../models/incident.dart';
import 'dart:developer' as developer;
import '../../../core/network/connectivity_service.dart';
import 'dart:async';
import '../../../core/network/api_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class IncidentService extends GetxController {
  final _db = DatabaseHelper.instance;
  final _imagePicker = ImagePicker();
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  late final ConnectivityService _connectivityService;
  
  RxList<Incident> incidents = <Incident>[].obs;
  RxBool isRecording = false.obs;
  String? _currentRecordingPath;
  final RxBool isSyncing = false.obs;
  
  @override
  void onInit() {
    super.onInit();
    // Initialize connectivity service
    try {
      _connectivityService = Get.find<ConnectivityService>();
    } catch (e) {
      _connectivityService = Get.put(ConnectivityService());
    }
    
    // Set up periodic sync
    _setupPeriodicSync();
    
    // Initialisation différée pour éviter de bloquer le thread principal
    Future.delayed(Duration.zero, () async {
      await _initRecorder();
    });
  }

  void _setupPeriodicSync() {
    // Sync every 15 minutes if there are pending incidents
    ever(_connectivityService.isConnected, (isConnected) {
      if (isConnected) {
        syncPendingIncidents();
      }
    });
    
    // Also set up a timer to check periodically
    Timer.periodic(const Duration(minutes: 15), (_) async {
      if (_connectivityService.isConnected.value) {
        await syncPendingIncidents();
      }
    });
  }

  Future<void> _initRecorder() async {
    try {
      await _recorder.openRecorder();
      developer.log('Audio recorder initialized successfully');
    } catch (e) {
      developer.log('Error initializing audio recorder', error: e);
    }
  }
  
  // Location handling
  Future<Position> getCurrentLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Location services are disabled.');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permissions are denied.');
      }
    }

    return await Geolocator.getCurrentPosition();
  }

  // Image capture
  Future<String?> captureImage() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1800,
        maxHeight: 1800,
      );
      return image?.path;
    } catch (e) {
      print('Error capturing image: $e');
      return null;
    }
  }

  // Voice recording
  Future<bool> startVoiceRecording() async {
    try {
      if (await Permission.microphone.request().isGranted) {
        final directory = await getApplicationDocumentsDirectory();
        _currentRecordingPath = path.join(
          directory.path,
          'recording_${DateTime.now().millisecondsSinceEpoch}.aac',
        );
        
        await _recorder.startRecorder(
          toFile: _currentRecordingPath,
          codec: Codec.aacADTS,
        );
        
        isRecording.value = true;
        return true;
      }
      return false;
    } catch (e) {
      print('Error starting recording: $e');
      return false;
    }
  }

  Future<String?> stopVoiceRecording() async {
    try {
      await _recorder.stopRecorder();
      isRecording.value = false;
      return _currentRecordingPath;
    } catch (e) {
      print('Error stopping recording: $e');
      return null;
    }
  }

  // Incident CRUD operations
  Future<bool> createIncident(Incident incident) async {
    try {
      await _db.insertIncident(incident.toMap());
      developer.log('Incident created: ${incident.id}');
      incidents.add(incident);
      return true;
    } catch (e, stackTrace) {
      developer.log('Error creating incident', error: e, stackTrace: stackTrace);
      rethrow;
      return false;
    }
  }

  Future<List<Incident>> getUserIncidents(int userId) async {
    try {
      final incidents = await _db.getIncidentsByUserId(userId);
      this.incidents.value = incidents.map((map) => Incident.fromMap(map)).toList();
      return this.incidents;
    } catch (e, stackTrace) {
      developer.log('Error getting user incidents', error: e, stackTrace: stackTrace);
      rethrow;
      return [];
    }
  }

  Future<List<Incident>> getUnsyncedIncidents() async {
    try {
      final incidents = await _db.getUnsyncedIncidents();
      return incidents.map((map) => Incident.fromMap(map)).toList();
    } catch (e, stackTrace) {
      developer.log('Error getting unsynced incidents', error: e, stackTrace: stackTrace);
      rethrow;
      return [];
    }
  }

  Future<void> syncIncident(Incident incident) async {
    try {
      // TODO: Implement API call to sync with server
      await _db.updateIncidentSyncStatus(incident.id, 'synced');
      developer.log('Incident synced: ${incident.id}');
    } catch (e, stackTrace) {
      developer.log('Error syncing incident', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // Sync operations
  Future<void> syncPendingIncidents() async {
    // Skip if already syncing
    if (isSyncing.value) {
      developer.log('Sync already in progress, skipping');
      return;
    }
    
    try {
      isSyncing.value = true;
      developer.log('Starting to sync pending incidents');
      
      // Check for internet connectivity
      final bool isConnected = await _connectivityService.checkConnectivity();
      if (!isConnected) {
        developer.log('No internet connection, sync aborted');
        return;
      }
      
      // Get unsynced incidents
      final List<Map<String, dynamic>> unsyncedIncidents = 
          await _db.getUnsyncedIncidents();
      
      if (unsyncedIncidents.isEmpty) {
        developer.log('No pending incidents to sync');
        return;
      }
      
      developer.log('Found ${unsyncedIncidents.length} incidents to sync');
      
      // Obtenir le service API pour envoyer les données
      final apiService = Get.find<ApiService>();
      
      // Vérifier le token avant de commencer
      final token = await const FlutterSecureStorage().read(key: 'jwt_token');
      if (token == null) {
        developer.log('Syncing incidents failed: No authentication token found');
        return;
      }
      developer.log('Using token for sync: ${token.substring(0, 10)}...');
      
      // For each pending incident, try to sync with the server
      for (var incidentMap in unsyncedIncidents) {
        try {
          final incident = Incident.fromMap(incidentMap);
          
          // Préparer les données pour l'API en format complet
          final Map<String, dynamic> incidentData = {
            'title': incident.title,
            'description': incident.description,
            'latitude': incident.latitude,
            'longitude': incident.longitude,
            'incident_type': incident.incidentType,
            'created_at': incident.createdAt.toIso8601String(),
            'user': incident.userId, // Changé de 'user_id' à 'user' pour correspondre au modèle Django
            'status': 'pending',
          };
          
          developer.log('Preparing to sync incident: ${incident.id}');
          developer.log('With data: $incidentData');
          
          // Appel direct de l'API pour créer un incident
          // au lieu d'utiliser la méthode syncIncident
          try {
            final response = await apiService.createIncident(incidentData);
            developer.log('API response for incident ${incident.id}: $response');
            
            // Après synchronisation réussie, mettre à jour le statut dans la DB locale
            await _db.updateIncidentSyncStatus(incident.id, 'synced');
            developer.log('Synced incident: ${incident.id}');
            
            // Update the incidents list if it contains this incident
            final index = incidents.indexWhere((inc) => inc.id == incident.id);
            if (index != -1) {
              final updatedIncident = Incident(
                id: incident.id,
                title: incident.title,
                description: incident.description,
                photoPath: incident.photoPath,
                photoUrl: incident.photoUrl,
                voiceNotePath: incident.voiceNotePath,
                latitude: incident.latitude,
                longitude: incident.longitude,
                createdAt: incident.createdAt,
                status: incident.status,
                incidentType: incident.incidentType,
                syncStatus: 'synced',
                userId: incident.userId,
              );
              incidents[index] = updatedIncident;
            }
          } catch (apiError) {
            developer.log('API error syncing incident ${incident.id}', error: apiError);
            // Ne pas marquer comme synchronisé en cas d'erreur
          }
        } catch (e, stackTrace) {
          developer.log('Error processing incident for sync', error: e, stackTrace: stackTrace);
        }
      }
      
      developer.log('Sync process completed');
    } catch (e, stackTrace) {
      developer.log('Error during sync process', error: e, stackTrace: stackTrace);
    } finally {
      isSyncing.value = false;
    }
  }

  // Mettre à jour le statut de synchronisation d'un incident
  Future<void> updateIncidentSyncStatus(int incidentId, String syncStatus) async {
    try {
      await _db.updateIncidentSyncStatus(incidentId, syncStatus);
      
      // Update the incident in the list if it exists
      final index = incidents.indexWhere((inc) => inc.id == incidentId);
      if (index != -1) {
        final incident = incidents[index];
        final updatedIncident = Incident(
          id: incident.id,
          title: incident.title,
          description: incident.description,
          photoPath: incident.photoPath,
          photoUrl: incident.photoUrl,
          voiceNotePath: incident.voiceNotePath,
          latitude: incident.latitude,
          longitude: incident.longitude,
          createdAt: incident.createdAt,
          status: incident.status,
          incidentType: incident.incidentType,
          syncStatus: syncStatus,
          userId: incident.userId,
        );
        incidents[index] = updatedIncident;
        incidents.refresh();
      }
      
      developer.log('Updated sync status for incident $incidentId to $syncStatus');
    } catch (e, stackTrace) {
      developer.log('Error updating incident sync status', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  @override
  void onClose() {
    _recorder.closeRecorder();
    super.onClose();
  }
}

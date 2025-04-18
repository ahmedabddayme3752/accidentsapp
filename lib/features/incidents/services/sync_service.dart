import 'dart:async';
import 'package:get/get.dart';
import 'dart:developer' as developer;
import '../../../core/network/connectivity_service.dart';
import '../../../core/network/api_service.dart';
import '../models/incident.dart';
import 'incident_service.dart';

class SyncService extends GetxController {
  final RxBool isSyncing = false.obs;
  late final Worker _connectivityWorker;
  
  final ConnectivityService _connectivityService = Get.find<ConnectivityService>();
  final IncidentService _incidentService = Get.find<IncidentService>();
  final ApiService _apiService = Get.find<ApiService>();
  
  @override
  void onInit() {
    super.onInit();
    _setupConnectivityListener();
    
    // Vérifier s'il y a des incidents à synchroniser au démarrage
    if (_connectivityService.isConnected.value) {
      syncPendingIncidents();
    }
  }
  
  @override
  void onClose() {
    _connectivityWorker.dispose();
    super.onClose();
  }
  
  // Configurer l'écouteur de connectivité
  void _setupConnectivityListener() {
    _connectivityWorker = ever(
      _connectivityService.connectivityChangedEvent, 
      (_) => _handleConnectivityChange()
    );
  }
  
  // Gérer les changements de connectivité
  Future<void> _handleConnectivityChange() async {
    if (_connectivityService.isConnected.value) {
      developer.log('SyncService: Connection restored, starting sync...');
      await syncPendingIncidents();
    } else {
      developer.log('SyncService: Connection lost');
    }
  }
  
  // Synchroniser les incidents en attente
  Future<void> syncPendingIncidents() async {
    if (isSyncing.value) {
      developer.log('SyncService: Sync already in progress, skipping');
      return;
    }
    
    try {
      isSyncing.value = true;
      developer.log('SyncService: ---------- STARTING SYNC OPERATION ----------');
      
      // Vérifier la connectivité avant de commencer
      final isConnected = await _connectivityService.checkConnectivity();
      developer.log('SyncService: Internet connection available: $isConnected');
      
      if (!isConnected) {
        developer.log('SyncService: No connection available, skipping sync');
        isSyncing.value = false;
        return;
      }
      
      // Verify authentication
      final token = await _apiService.getStoredToken();
      if (token == null) {
        developer.log('SyncService: No authentication token found, skipping sync');
        isSyncing.value = false;
        return;
      }
      developer.log('SyncService: Authentication token found, proceeding with sync');
      
      // Récupérer les incidents non synchronisés
      final unsyncedIncidents = await _incidentService.getUnsyncedIncidents();
      developer.log('SyncService: Found ${unsyncedIncidents.length} unsynced incidents');
      
      if (unsyncedIncidents.isEmpty) {
        developer.log('SyncService: No incidents to sync, operation completed');
        isSyncing.value = false;
        return;
      }
      
      // Synchroniser chaque incident
      int successCount = 0;
      int failCount = 0;
      
      for (final incident in unsyncedIncidents) {
        try {
          developer.log('SyncService: Processing incident ID ${incident.id}');
          await _syncIncident(incident);
          successCount++;
        } catch (e) {
          developer.log('SyncService: Error syncing incident ${incident.id}', error: e);
          failCount++;
          // Continuer avec le prochain incident même si celui-ci échoue
        }
      }
      
      developer.log('SyncService: Sync completed - Success: $successCount, Failed: $failCount');
      developer.log('SyncService: ---------- SYNC OPERATION COMPLETED ----------');
    } catch (e) {
      developer.log('SyncService: Error during sync operation', error: e);
      developer.log('SyncService: ---------- SYNC OPERATION FAILED ----------');
    } finally {
      isSyncing.value = false;
    }
  }
  
  // Synchroniser un incident spécifique
  Future<void> _syncIncident(Incident incident) async {
    try {
      developer.log('SyncService: -------- SYNCING INCIDENT ${incident.id} --------');
      developer.log('SyncService: Incident details: ${incident.title}, type: ${incident.incidentType}, userID: ${incident.userId}');
      
      // Check user ID
      if (incident.userId == null || incident.userId <= 0) {
        developer.log('SyncService: WARNING - Invalid user ID: ${incident.userId}. Setting to default value 1.');
        // Set a default value for testing
        incident = incident.copyWith(userId: 1);
      }
      
      // Convertir l'incident en format approprié pour l'API
      final incidentData = {
        'title': incident.title,
        'description': incident.description,
        'latitude': incident.latitude,
        'longitude': incident.longitude,
        'incident_type': incident.incidentType,
        'created_at': incident.createdAt.toIso8601String(),
        'photo_path': incident.photoPath,
        'voice_note_path': incident.voiceNotePath,
        'status': 'pending',
        'sync_status': 'pending',
        'user': incident.userId, // Make sure to include the user ID for the API
      };
      
      developer.log('SyncService: Incident data prepared for API: $incidentData');
      
      // Get authentication token
      final token = await _apiService.getStoredToken();
      developer.log('SyncService: Using auth token: ${token != null ? 'valid token exists' : 'token is null'}');
      
      // Check connectivity again before API call
      final isConnected = await _connectivityService.checkConnectivity();
      developer.log('SyncService: Connectivity check before API call: $isConnected');
      
      if (!isConnected) {
        developer.log('SyncService: Failed to sync incident ${incident.id} - No internet connection');
        throw Exception('No internet connection');
      }
      
      // Envoyer l'incident au serveur
      developer.log('SyncService: Sending incident to API...');
      final response = await _apiService.syncIncident(incidentData);
      
      if (response == null) {
        developer.log('SyncService: API returned null response for incident ${incident.id}');
        throw Exception('API returned null response');
      }
      
      developer.log('SyncService: API response for incident ${incident.id}: $response');
      
      // Si la synchronisation réussit, mettre à jour l'état de l'incident local
      await _incidentService.updateIncidentSyncStatus(incident.id, 'synced');
      
      developer.log('SyncService: Incident ${incident.id} synced successfully');
      developer.log('SyncService: -------- SYNC COMPLETE FOR INCIDENT ${incident.id} --------');
    } catch (e) {
      developer.log('SyncService: Failed to sync incident ${incident.id}', error: e);
      developer.log('SyncService: -------- SYNC FAILED FOR INCIDENT ${incident.id} --------');
      throw e; // Propager l'erreur pour la gestion par l'appelant
    }
  }
  
  // Méthode publique pour déclencher manuellement la synchronisation
  Future<void> manualSync() async {
    developer.log('Manual sync requested');
    return syncPendingIncidents();
  }
} 
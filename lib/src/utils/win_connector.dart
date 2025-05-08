import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A class that connects to the BLE server and sends/receives messages
/// Make sure to call [initialize] before using [invokeMethod]
class WinConnector {
  int _requestId = 0;
  StreamSubscription? _stdoutSubscription;
  StreamSubscription? _stderrSubscription;
  Process? _bleServer;
  final _responseStreamController = StreamController.broadcast();

  Future<void> initialize({Function(dynamic)? onData, required String serverPath}) async {
    File bleFile = File(serverPath);
    _bleServer = await Process.start(bleFile.path, []);
    _stdoutSubscription = _bleServer?.stdout.listen((event) {
      var listData = _dataParser(event);
      for (var data in listData) {
        _handleResponse(data);
        onData?.call(data);
      }
    });

    _stderrSubscription = _bleServer?.stderr.listen((event) {
      throw String.fromCharCodes(event);
    });
  }

  Future invokeMethod(String method, {Map<String, dynamic>? args, bool waitForResult = true}) async {
    Map<String, dynamic> result = args ?? {};
    // If we don't need to wait for the result, just send the message and return
    if (!waitForResult) {
      _sendMessage(method: method, args: result);
      return;
    }
    // If we need to wait for the result, we need to generate a unique ID
    int uniqID = _requestId++;
    result["_id"] = uniqID;
    _sendMessage(method: method, args: result);
    var data = await _responseStreamController.stream.firstWhere((element) => element["id"] == uniqID);
    if (data["error"] != null) throw data["error"];
    return data['result'];
  }

  void dispose() {
    _stderrSubscription?.cancel();
    _stdoutSubscription?.cancel();
    _bleServer?.kill();
  }

  void _handleResponse(response) {
    try {
      if (response["_type"] == "response") {
        _responseStreamController.add({
          "id": response["_id"],
          "result": response["result"],
          "error": response["error"],
        });
      }
    } catch (_) {}
  }

  void _sendMessage({required String method, Map<String, dynamic>? args}) {
    Map<String, dynamic> result = {"cmd": method};
    if (args != null) result.addAll(args);
    String data = json.encode(result);
    List<int> dataBufInt = utf8.encode(data);
    List<int> lenBufInt = _createUInt32LE(dataBufInt.length);
    _bleServer?.stdin.add(lenBufInt);
    _bleServer?.stdin.add(dataBufInt);
  }

  List<int> _createUInt32LE(int value) {
    final result = Uint8List(4);
    for (int i = 0; i < 4; i++, value >>= 8) {
      result[i] = value & 0xFF;
    }
    return result;
  }

  List<dynamic> _dataParser(event) {
    var data = String.fromCharCodes(event);
    final List<Map<String, dynamic>> extractedJsons = [];
    final jsonRegExp = RegExp(r'\{[^{}]*?(?:\{.*?\}[^{}]*?)*\}', dotAll: true);

    for (final match in jsonRegExp.allMatches(data)) {
      final jsonString = match.group(0);
      try {
        if (jsonString != null) {
          final decoded = jsonDecode(jsonString);
          extractedJsons.add(decoded);
        }
      } catch (_) {
        // Skip malformed JSON
      }
    }

    return extractedJsons;
  }
}

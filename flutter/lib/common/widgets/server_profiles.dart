import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

const String kLocalOptionServerProfiles = 'server-profiles';
const String kLocalOptionServerAccounts = 'server-accounts';

class ServerProfile {
  String name;
  ServerConfig config;

  ServerProfile(this.name, this.config);

  Map<String, String> toJson() => {
        'name': name,
        'host': config.idServer,
        'relay': config.relayServer,
        'api': config.apiServer,
        'key': config.key,
      };

  static ServerProfile fromJson(Map<String, dynamic> json) => ServerProfile(
      (json['name'] ?? '').toString(),
      ServerConfig(
          idServer: (json['host'] ?? '').toString(),
          relayServer: (json['relay'] ?? '').toString(),
          apiServer: (json['api'] ?? '').toString(),
          key: (json['key'] ?? '').toString()));

  bool sameServer(ServerConfig other) =>
      _norm(config.idServer) == _norm(other.idServer) &&
      _norm(config.relayServer) == _norm(other.relayServer) &&
      _norm(config.apiServer) == _norm(other.apiServer) &&
      config.key.trim() == other.key.trim();

  static String _norm(String s) {
    s = s.trim();
    return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
  }
}

List<ServerProfile> decodeServerProfiles(String text) {
  if (text.trim().isEmpty) return [];
  try {
    final list = jsonDecode(text);
    if (list is! List) return [];
    return list
        .whereType<Map>()
        .map((e) => ServerProfile.fromJson(Map<String, dynamic>.from(e)))
        .where((p) => p.name.isNotEmpty)
        .toList();
  } catch (e) {
    debugPrint('Invalid server profiles: $e');
    return [];
  }
}

String encodeServerProfiles(List<ServerProfile> profiles) =>
    jsonEncode(profiles.map((e) => e.toJson()).toList());

int indexOfServerProfile(List<ServerProfile> profiles, ServerConfig current) =>
    profiles.indexWhere((p) => p.sameServer(current));

/// Index used for the built-in public server, which has all fields empty.
const int kPublicServerIndex = -1;

bool _isPublicServer(ServerConfig c) =>
    ServerProfile('', ServerConfig()).sameServer(c);

/// The saved server matching [current], [kPublicServerIndex], or null.
int? selectedServerIndex(List<ServerProfile> profiles, ServerConfig current) {
  final i = indexOfServerProfile(profiles, current);
  if (i >= 0) return i;
  return _isPublicServer(current) ? kPublicServerIndex : null;
}

class ServerProfiles {
  static final ServerProfiles instance = ServerProfiles._();
  ServerProfiles._() {
    profiles.value = decodeServerProfiles(
        bind.mainGetLocalOption(key: kLocalOptionServerProfiles));
  }

  final RxList<ServerProfile> profiles = <ServerProfile>[].obs;
  final Rx<ServerConfig> current = ServerConfig().obs;
  final RxBool switching = false.obs;

  static bool get hidden =>
      bind.isDisableSettings() ||
      bind.mainGetBuildinOption(key: kOptionHideServerSetting) == 'Y' ||
      isOptionFixed('custom-rendezvous-server');

  Future<void> refresh() async {
    try {
      current.value =
          ServerConfig.fromOptions(jsonDecode(await bind.mainGetOptions()));
    } catch (e) {
      debugPrint('Failed to read server options: $e');
    }
  }

  /// Keeps the account of [oldApiServer] aside instead of logging it out,
  /// and brings back the account saved earlier for [newApiServer], if any.
  Future<void> switchAccount(String oldApiServer, String newApiServer) async {
    if (oldApiServer == newApiServer) return;
    final userModel = gFFI.userModel;
    Map<String, dynamic> accounts = {};
    final text = bind.mainGetLocalOption(key: kLocalOptionServerAccounts);
    if (text.isNotEmpty) {
      try {
        accounts = Map<String, dynamic>.from(jsonDecode(text));
      } catch (e) {
        debugPrint('Invalid server accounts: $e');
      }
    }
    final token = bind.mainGetLocalOption(key: 'access_token');
    if (oldApiServer.isNotEmpty && token.isNotEmpty) {
      accounts[oldApiServer] = {
        'access_token': token,
        'user_info': bind.mainGetLocalOption(key: 'user_info'),
      };
    }
    await userModel.reset(resetOther: true);
    final saved = accounts.remove(newApiServer);
    await bind.mainSetLocalOption(
        key: kLocalOptionServerAccounts, value: jsonEncode(accounts));
    if (saved is Map) {
      await bind.mainSetLocalOption(
          key: 'access_token', value: (saved['access_token'] ?? '').toString());
      await bind.mainSetLocalOption(
          key: 'user_info', value: (saved['user_info'] ?? '').toString());
      userModel.refreshCurrentUser();
    }
  }

  int? get currentIndex => selectedServerIndex(profiles, current.value);

  ServerConfig configAt(int index) =>
      index == kPublicServerIndex ? ServerConfig() : profiles[index].config;

  Future<void> _save() async {
    await bind.mainSetLocalOption(
        key: kLocalOptionServerProfiles, value: encodeServerProfiles(profiles));
  }

  Future<int> saveAs(String name, ServerConfig c) async {
    final copy = ServerConfig(
        idServer: c.idServer,
        relayServer: c.relayServer,
        apiServer: c.apiServer,
        key: c.key);
    var i = profiles.indexWhere((p) => p.name == name);
    if (i >= 0) {
      profiles[i] = ServerProfile(name, copy);
    } else {
      profiles.add(ServerProfile(name, copy));
      i = profiles.length - 1;
    }
    await _save();
    return i;
  }

  Future<void> remove(int index) async {
    if (index < 0 || index >= profiles.length) return;
    profiles.removeAt(index);
    await _save();
  }

  Future<void> apply(int index) async {
    if (index < kPublicServerIndex ||
        index >= profiles.length ||
        switching.value) return;
    final c = configAt(index);
    switching.value = true;
    final errMsgs = [''.obs, ''.obs, ''.obs];
    try {
      final ok = await setServerConfig(
          null,
          errMsgs,
          ServerConfig(
              idServer: c.idServer,
              relayServer: c.relayServer,
              apiServer: c.apiServer,
              key: c.key));
      final err = errMsgs
          .map((e) => e.value)
          .firstWhere((e) => e.isNotEmpty, orElse: () => translate('Failed'));
      showToast(ok ? translate('Successful') : err);
    } finally {
      switching.value = false;
    }
  }
}

String _describeServer(ServerConfig c) => [
      '${translate('ID Server')}: ${c.idServer.isEmpty ? '-' : c.idServer}',
      '${translate('Relay Server')}: ${c.relayServer.isEmpty ? '-' : c.relayServer}',
      '${translate('API Server')}: ${c.apiServer.isEmpty ? '-' : c.apiServer}',
    ].join('\n');

List<DropdownMenuItem<int>> _profileItems(List<ServerProfile> profiles) => [
      DropdownMenuItem<int>(
        value: kPublicServerIndex,
        child:
            Text(translate('Public server'), overflow: TextOverflow.ellipsis),
      ),
      for (var i = 0; i < profiles.length; i++)
        DropdownMenuItem<int>(
          value: i,
          child: Tooltip(
            message: _describeServer(profiles[i].config),
            waitDuration: const Duration(milliseconds: 800),
            child: Text(profiles[i].name, overflow: TextOverflow.ellipsis),
          ),
        ),
    ];

/// Main window dropdown: choosing a saved server switches to it at once.
class ServerProfileSelector extends StatefulWidget {
  final TextStyle? style;

  const ServerProfileSelector({Key? key, this.style}) : super(key: key);

  @override
  State<ServerProfileSelector> createState() => _ServerProfileSelectorState();
}

class _ServerProfileSelectorState extends State<ServerProfileSelector> {
  final model = ServerProfiles.instance;

  @override
  void initState() {
    super.initState();
    model.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final profiles = model.profiles.toList();
      model.current.value;
      final index = model.currentIndex;
      return DropdownButton<int>(
        isExpanded: true,
        isDense: true,
        underline: const SizedBox.shrink(),
        style: widget.style,
        iconEnabledColor: const Color(0xFFDDDDDD),
        value: index,
        hint: Text(translate('Not saved'), overflow: TextOverflow.ellipsis),
        items: _profileItems(profiles),
        onChanged: !model.switching.value
            ? (i) {
                if (i != null && i != index) model.apply(i);
              }
            : null,
      );
    });
  }
}

/// Row for the ID/Relay Server dialog: pick a saved server to fill the
/// fields, save the fields under a name, or delete the picked one.
/// [controllers] are the dialog's id, relay, api and key fields.
class ServerProfileEditor extends StatefulWidget {
  final List<TextEditingController> controllers;
  final double? labelWidth;
  final double labelSpacing;

  const ServerProfileEditor(
      {Key? key,
      required this.controllers,
      this.labelWidth,
      this.labelSpacing = 8})
      : super(key: key);

  @override
  State<ServerProfileEditor> createState() => _ServerProfileEditorState();
}

class _ServerProfileEditorState extends State<ServerProfileEditor> {
  final model = ServerProfiles.instance;
  int? selected;
  final nameCtrl = TextEditingController();

  ServerConfig get _fields => ServerConfig(
      idServer: widget.controllers[0].text,
      relayServer: widget.controllers[1].text,
      apiServer: widget.controllers[2].text,
      key: widget.controllers[3].text);

  @override
  void initState() {
    super.initState();
    _select(selectedServerIndex(model.profiles, _fields));
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    super.dispose();
  }

  void _select(int? i) {
    selected = i;
    nameCtrl.text = i == kPublicServerIndex
        ? translate('Public server')
        : i != null && i < model.profiles.length
            ? model.profiles[i].name
            : '';
  }

  void _pick(int? i) {
    if (i == null || i >= model.profiles.length) return;
    final c = model.configAt(i);
    widget.controllers[0].text = c.idServer;
    widget.controllers[1].text = c.relayServer;
    widget.controllers[2].text = c.apiServer;
    widget.controllers[3].text = c.key;
    setState(() => _select(i));
  }

  Future<void> _delete() async {
    final i = selected;
    if (i == null || i < 0) return;
    await model.remove(i);
    setState(() => _select(null));
  }

  void _askName() {
    final i = selected;
    final ctrl = TextEditingController(
        text: i != null && i >= 0 && i < model.profiles.length
            ? model.profiles[i].name
            : widget.controllers[0].text.trim());
    gFFI.dialogManager.show((setState, close, context) {
      submit() async {
        final name = ctrl.text.trim();
        if (name.isEmpty) return;
        close();
        final saved = await model.saveAs(name, _fields);
        if (mounted) this.setState(() => _select(saved));
        showToast(translate('Successful'));
      }

      return CustomAlertDialog(
        title: Text(translate('Save server')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 400),
          child: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(labelText: translate('Name')),
            onSubmitted: (_) => submit(),
          ),
        ),
        actions: [
          dialogButton('Cancel', onPressed: close, isOutline: true),
          dialogButton('OK', onPressed: submit),
        ],
        onSubmit: submit,
        onCancel: close,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final profiles = model.profiles.toList();
      final value =
          selected != null && selected! < profiles.length ? selected : null;
      final canDelete = value != null && value >= 0;
      return Row(
        children: [
          if (widget.labelWidth != null) ...[
            SizedBox(
                width: widget.labelWidth,
                child: Text(translate('Saved servers'))),
            SizedBox(width: widget.labelSpacing),
          ],
          Expanded(
            // DropdownButton opens its menu on the navigator, which sits
            // below this dialog's overlay; DropdownMenu opens in this overlay.
            child: DropdownMenu<int>(
              key: ValueKey(profiles.length),
              controller: nameCtrl,
              initialSelection: value,
              expandedInsets: EdgeInsets.zero,
              enableFilter: false,
              enableSearch: false,
              requestFocusOnTap: false,
              hintText: translate('Not saved'),
              inputDecorationTheme: Theme.of(context)
                  .inputDecorationTheme
                  .copyWith(
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 12)),
              dropdownMenuEntries: [
                DropdownMenuEntry<int>(
                    value: kPublicServerIndex,
                    label: translate('Public server')),
                for (var i = 0; i < profiles.length; i++)
                  DropdownMenuEntry<int>(value: i, label: profiles[i].name),
              ],
              onSelected: _pick,
            ),
          ),
          IconButton(
            tooltip: translate('Save server'),
            icon: const Icon(Icons.save_outlined),
            onPressed: _askName,
          ),
          IconButton(
            tooltip: translate('Delete'),
            icon: const Icon(Icons.delete_outline),
            onPressed: canDelete ? _delete : null,
          ),
        ],
      );
    });
  }
}

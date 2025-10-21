import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:flutter_timezone/flutter_timezone.dart';

void main() async {
    WidgetsFlutterBinding.ensureInitialized();
    await _NotificationService.instance.init();
    runApp(const MyApp());
}

class MyApp extends StatelessWidget {
    const MyApp({super.key});
    @override
    Widget build(BuildContext context) {
        return MaterialApp(
            title: 'RemindMe',
            theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
            home: const HomeScreen(),
        );
    }
}

/* ===================== モデル ===================== */

class Reminder {
    final int id; // 通知IDのベース
    final String title;
    final String? note;
    final DateTime when;
    final bool useSnooze;
    final int? snoozeIntervalMinutes;
    final int? snoozeMaxCount; // 「最大全通知回数（初回含む）」と解釈
    final int snoozeCount; // ユーザーが「後で通知」を押した回数（表示用）
    final bool isDone; // 完了ボタンが押されたか
    final List<int> scheduledNotificationIds; // 予約済みの通知ID群（キャンセル用）
    final DateTime? finishedAt; // 終了（完了 or 通知回数消化）時刻

    const Reminder({
        required this.id,
        required this.title,
        required this.when,
        this.note,
        this.useSnooze = false,
        this.snoozeIntervalMinutes,
        this.snoozeMaxCount,
        this.snoozeCount = 0,
        this.isDone = false,
        this.scheduledNotificationIds = const [],
        this.finishedAt,
    });

    Reminder copyWith({
        int? id,
        String? title,
        String? note,
        DateTime? when,
        bool? useSnooze,
        int? snoozeIntervalMinutes,
        int? snoozeMaxCount,
        int? snoozeCount,
        bool? isDone,
        List<int>? scheduledNotificationIds,
        DateTime? finishedAt,
    }) {
        return Reminder(
            id: id ?? this.id,
            title: title ?? this.title,
            note: note ?? this.note,
            when: when ?? this.when,
            useSnooze: useSnooze ?? this.useSnooze,
            snoozeIntervalMinutes: snoozeIntervalMinutes ?? this.snoozeIntervalMinutes,
            snoozeMaxCount: snoozeMaxCount ?? this.snoozeMaxCount,
            snoozeCount: snoozeCount ?? this.snoozeCount,
            isDone: isDone ?? this.isDone,
            scheduledNotificationIds: scheduledNotificationIds ?? this.scheduledNotificationIds,
            finishedAt: finishedAt ?? this.finishedAt,
        );
    }

    bool get isExpiredAll =>
        useSnooze &&
        snoozeMaxCount != null &&
        snoozeIntervalMinutes != null &&
        DateTime.now().isAfter(when.add(Duration(minutes: snoozeIntervalMinutes! * ((snoozeMaxCount ?? 1) - 1))));
}

/* ============== 通知サービス（シングルトン） ============== */

class _NotificationService {
    _NotificationService._();
    static final _NotificationService instance = _NotificationService._();

    final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
    bool _initialized = false;

    static const String actionSnooze = 'action_snooze';
    static const String actionComplete = 'action_complete';
    static const String channelId = 'remindme_channel';
    static const String channelName = 'RemindMe Notifications';
    static const String channelDesc = 'Task reminders with actions';

    Future<void> init() async {
        if (_initialized) return;

        // Timezone 初期化
        tzdata.initializeTimeZones();
        final String local = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(local));

        const AndroidInitializationSettings androidInit =
            AndroidInitializationSettings('@mipmap/ic_launcher');
        const InitializationSettings initSettings = InitializationSettings(android: androidInit);

        await _plugin.initialize(
            initSettings,
            onDidReceiveNotificationResponse: _onNotificationResponse,
            onDidReceiveBackgroundNotificationResponse: _onNotificationResponseBackground,
        );

        // Android 13+ 通知許可リクエスト
        await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();

        // アクションボタンのカテゴリーはAndroid側で自動処理（flutter_local_notifications v17 以降）

        _initialized = true;
    }

    @pragma('vm:entry-point')
    static void _onNotificationResponseBackground(NotificationResponse response) {
        _onNotificationResponse(response); // フォア＋バックを同じハンドラに
    }

    static Future<void> _onNotificationResponse(NotificationResponse response) async {
        final String? payload = response.payload; // JSON風にしてID等を持たせる
        if (payload == null) return;

        // payload: "id:<number>"
        final int id = int.tryParse(payload.split(':').last) ?? -1;
        if (id == -1) return;

        final String actionId = response.actionId ?? '';

        // アプリ実行中の状態へ届ける：簡易的に通知イベントバスを叩く
        _NotificationBus.instance.add(_NotificationEvent(id: id, actionId: actionId));
    }

    Future<void> cancel(int notificationId) async {
        await _plugin.cancel(notificationId);
    }

    Future<void> cancelMany(List<int> ids) async {
        for (final int id in ids) {
            await _plugin.cancel(id);
        }
    }

    Future<void> scheduleSingle({
        required int id,
        required String title,
        required String body,
        required DateTime when,
    }) async {
        final AndroidNotificationDetails android = AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription: channelDesc,
            importance: Importance.max,
            priority: Priority.high,
            category: AndroidNotificationCategory.reminder,
            actions: <AndroidNotificationAction>[
                AndroidNotificationAction(
                    actionSnooze,
                    '後で通知',
                    showsUserInterface: true,
                    // 押した通知を消す（次の再通知だけ出したいので推奨）
                    cancelNotification: true,
                ),
                AndroidNotificationAction(
                    actionComplete,
                    '完了',
                    showsUserInterface: true,
                    // v17系には destructive / semanticAction が無いので未指定でOK
                    cancelNotification: true,
                ),
            ],
        );



        final NotificationDetails details = NotificationDetails(android: android);
        final tz.TZDateTime tzWhen = tz.TZDateTime.from(when, tz.local);

        await _plugin.zonedSchedule(
            id,
            title,
            body,
            tzWhen,
            details,
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
            payload: 'id:$id',
            matchDateTimeComponents: null,
        );
    }
}

/* ====== 通知アクションの結果をアプリに届ける簡易バス ====== */

class _NotificationEvent {
    final int id;
    final String actionId;
    _NotificationEvent({required this.id, required this.actionId});
}

class _NotificationBus extends ChangeNotifier {
    _NotificationBus._();
    static final _NotificationBus instance = _NotificationBus._();
    _NotificationEvent? _last;
    void add(_NotificationEvent e) {
        _last = e;
        notifyListeners();
    }
    _NotificationEvent? get last => _last;
}

/* ===================== UI 本体 ===================== */

class HomeScreen extends StatefulWidget {
    const HomeScreen({super.key});
    @override
    State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with ChangeNotifier {
    final List<Reminder> _reminders = <Reminder>[
        Reminder(id: 1001, title: 'ミーティング資料送付', when: DateTime.now().add(const Duration(minutes: 90)), useSnooze: true, snoozeIntervalMinutes: 10, snoozeMaxCount: 3),
        Reminder(id: 1002, title: '牛乳を買う', when: DateTime.now().add(const Duration(minutes: 45))),
        Reminder(id: 1003, title: '定例MTG', when: DateTime.now().add(const Duration(days: 1, hours: 1)), note: '毎週の進捗確認'),
        Reminder(id: 1004, title: '期限過ぎタスク例', when: DateTime.now().subtract(const Duration(minutes: 5)), note: '例示'),
    ];

    @override
    void initState() {
        super.initState();
        // 通知アクションのイベント購読
        _NotificationBus.instance.addListener(_onNotificationAction);
        // 起動時に期限切れ/全通知消化のタスクを「終了した」へ移動
        _reapFinished();
    }

    @override
    void dispose() {
        _NotificationBus.instance.removeListener(_onNotificationAction);
        super.dispose();
    }

    void _onNotificationAction() {
        final _NotificationEvent? e = _NotificationBus.instance.last;
        if (e == null) return;

        // 該当タスクを特定
        final int idx = _reminders.indexWhere((r) => r.scheduledNotificationIds.contains(e.id) || r.id == e.id);
        if (idx < 0) return;
        final Reminder r = _reminders[idx];

        if (e.actionId == _NotificationService.actionSnooze) {
            // 「後で通知」：カウント増やし、次回を予約（最大回数まで）
            if (r.useSnooze && r.snoozeIntervalMinutes != null && r.snoozeMaxCount != null) {
                final int nextOrdinal = r.snoozeCount + 1; // 押下回数ベースの見せ方
                if (nextOrdinal < (r.snoozeMaxCount ?? 1)) {
                    final DateTime nextTime = DateTime.now().add(Duration(minutes: r.snoozeIntervalMinutes!));
                    final int nextId = _makeNotifId(r.id, nextOrdinal);
                    _NotificationService.instance.scheduleSingle(
                        id: nextId,
                        title: r.title,
                        body: r.note ?? '',
                        when: nextTime,
                    );
                    setState(() {
                        _reminders[idx] = r.copyWith(
                            snoozeCount: r.snoozeCount + 1,
                            scheduledNotificationIds: List<int>.from(r.scheduledNotificationIds)..add(nextId),
                        );
                    });
                } else {
                    // もう上限：終了扱い
                    setState(() {
                        _reminders[idx] = r.copyWith(isDone: true, finishedAt: DateTime.now());
                    });
                }
            }
        } else if (e.actionId == _NotificationService.actionComplete) {
            // 「完了」：残りの通知をキャンセルして終了扱い
            _NotificationService.instance.cancelMany(r.scheduledNotificationIds);
            setState(() {
                _reminders[idx] = r.copyWith(isDone: true, finishedAt: DateTime.now());
            });
        }
    }

    // 表示リストを2つに分割（48時間保持）
    List<Reminder> get _activeReminders {
        _reapFinished();
        return _reminders.where((r) => !(r.isDone || r.isExpiredAll)).toList()
            ..sort((a, b) => a.when.compareTo(b.when));
    }

    List<Reminder> get _finishedReminders {
        final DateTime now = DateTime.now();
        return _reminders.where((r) {
            if (!(r.isDone || r.isExpiredAll)) return false;
            final DateTime t = r.finishedAt ??
                // 「指定回数通知し終わった」場合は最終予定時刻を finishedAt とみなす
                (r.useSnooze && r.snoozeIntervalMinutes != null && r.snoozeMaxCount != null
                    ? r.when.add(Duration(minutes: r.snoozeIntervalMinutes! * ((r.snoozeMaxCount ?? 1) - 1)))
                    : r.when);
            return now.difference(t).inHours < 48;
        }).toList()
          ..sort((a, b) => (a.finishedAt ?? a.when).compareTo(b.finishedAt ?? b.when));
    }

    void _reapFinished() {
        // finishedAt から48時間超のものはUIから除外（メモリ保持は本例では省略）
        // 永続化する場合はDBで削除/アーカイブ
    }

    int _makeNotifId(int baseId, int ordinal) => baseId * 100 + ordinal; // 100倍+通し番号で衝突回避

    Future<void> _scheduleAll(Reminder r) async {
        // 初回＋（上限-1）回の合計を予約（どれもキャンセル可）
        final List<int> ids = <int>[];
        if (!r.useSnooze || r.snoozeIntervalMinutes == null || r.snoozeMaxCount == null) {
            final int id0 = _makeNotifId(r.id, 0);
            await _NotificationService.instance.scheduleSingle(
                id: id0,
                title: r.title,
                body: r.note ?? '',
                when: r.when,
            );
            ids.add(id0);
        } else {
            final int max = r.snoozeMaxCount!.clamp(1, 99);
            for (int k = 0; k < max; k++) {
                final DateTime whenK = r.when.add(Duration(minutes: r.snoozeIntervalMinutes! * k));
                final int idK = _makeNotifId(r.id, k);
                await _NotificationService.instance.scheduleSingle(
                    id: idK,
                    title: r.title,
                    body: r.note ?? '',
                    when: whenK,
                );
                ids.add(idK);
            }
        }
        final int idx = _reminders.indexWhere((x) => x.id == r.id);
        if (idx >= 0) {
            setState(() {
                _reminders[idx] = r.copyWith(scheduledNotificationIds: ids);
            });
        }
    }

    @override
    Widget build(BuildContext context) {
        final List<Reminder> upcoming = _activeReminders;
        final List<Reminder> finished = _finishedReminders;

        return Scaffold(
            appBar: AppBar(title: const Text('リマインダー'), centerTitle: true),
            body: SafeArea(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                            // 登録（大きめ）
                            SizedBox(
                                height: 64,
                                child: FilledButton.icon(
                                    icon: const Icon(Icons.add, size: 24),
                                    onPressed: () async {
                                        final Reminder? created = await showModalBottomSheet<Reminder>(
                                            context: context,
                                            isScrollControlled: true,
                                            useSafeArea: true,
                                            showDragHandle: true,
                                            builder: (_) => _ReminderSheet(),
                                        );
                                        if (created != null) {
                                            setState(() => _reminders.add(created));
                                            await _scheduleAll(created);
                                            ScaffoldMessenger.of(context).showSnackBar(
                                                const SnackBar(content: Text('リマインドを作成・通知予約しました')),
                                            );
                                        }
                                    },
                                    label: const Text('登録', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                                ),
                            ),
                            const SizedBox(height: 20),

                            // 次のリマインド
                            Row(
                                children: [
                                    const Text('次のリマインド', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                                    const SizedBox(width: 8),
                                    Badge(label: Text('${upcoming.length}')),
                                ],
                            ),
                            const SizedBox(height: 8),

                            Expanded(
                                child: upcoming.isEmpty
                                    ? const _EmptyList()
                                    : ListView.separated(
                                        itemCount: upcoming.length,
                                        separatorBuilder: (_, __) => const Divider(height: 1),
                                        itemBuilder: (context, index) {
                                            final Reminder r = upcoming[index];
                                            final Color? tileColor = _tileColorFor(r);
                                            final String subtitleText = _subtitleFor(r);

                                            return Container(
                                                color: tileColor,
                                                child: ListTile(
                                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                                    leading: Icon(r.isDone ? Icons.check_circle : Icons.alarm),
                                                    title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                                    subtitle: Text(subtitleText, maxLines: 2),
                                                    trailing: Row(
                                                        mainAxisSize: MainAxisSize.min,
                                                        children: [
                                                            IconButton(
                                                                tooltip: '編集',
                                                                icon: const Icon(Icons.edit),
                                                                onPressed: () async {
                                                                    final int i = _reminders.indexWhere((x) => x.id == r.id);
                                                                    final Reminder? edited = await showModalBottomSheet<Reminder>(
                                                                        context: context,
                                                                        isScrollControlled: true,
                                                                        useSafeArea: true,
                                                                        showDragHandle: true,
                                                                        builder: (_) => _ReminderSheet(initial: r),
                                                                    );
                                                                    if (edited != null) {
                                                                        // 既存の通知をキャンセルして、改めて予約
                                                                        await _NotificationService.instance.cancelMany(r.scheduledNotificationIds);
                                                                        setState(() => _reminders[i] = edited.copyWith(scheduledNotificationIds: []));
                                                                        await _scheduleAll(edited);
                                                                        ScaffoldMessenger.of(context).showSnackBar(
                                                                            const SnackBar(content: Text('リマインドを更新しました')),
                                                                        );
                                                                    }
                                                                },
                                                            ),
                                                            IconButton(
                                                                tooltip: '削除',
                                                                icon: const Icon(Icons.delete),
                                                                onPressed: () async {
                                                                    final bool? ok = await _confirmDelete(context);
                                                                    if (ok == true) {
                                                                        await _NotificationService.instance.cancelMany(r.scheduledNotificationIds);
                                                                        setState(() => _reminders.removeWhere((x) => x.id == r.id));
                                                                        ScaffoldMessenger.of(context).showSnackBar(
                                                                            const SnackBar(content: Text('リマインドを削除しました')),
                                                                        );
                                                                    }
                                                                },
                                                            ),
                                                        ],
                                                    ),
                                                ),
                                            );
                                        },
                                    ),
                            ),

                            // 終了したリマインド（48時間保持）
                            if (finished.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                const Text('終了したリマインド（48時間保持）', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                                const SizedBox(height: 8),
                                SizedBox(
                                    height: 160,
                                    child: ListView.separated(
                                        itemCount: finished.length,
                                        separatorBuilder: (_, __) => const Divider(height: 1),
                                        itemBuilder: (context, index) {
                                            final r = finished[index];
                                            final when = r.finishedAt ?? r.when;
                                            return ListTile(
                                                leading: const Icon(Icons.history),
                                                title: Text(r.title),
                                                subtitle: Text('終了: ${_fmtDateTime(when)}'),
                                            );
                                        },
                                    ),
                                ),
                            ],
                        ],
                    ),
                ),
            ),
        );
    }

    /// 状態に応じた行の色
    Color? _tileColorFor(Reminder r) {
        final Duration diff = r.when.difference(DateTime.now());
        final bool overdue = diff.isNegative;
        final bool warningSoon = !overdue && diff < const Duration(hours: 1);
        final bool snoozing = r.snoozeCount > 0;

        if (overdue || snoozing) return Colors.red.withOpacity(0.12);
        if (warningSoon) return Colors.amber.withOpacity(0.16);
        return null;
    }

    /// サブタイトル：「YYYY/MM/DD HH:mm（あとX）」＋ スヌーズ回数
    String _subtitleFor(Reminder r) {
        final String base = '${_fmtDateTime(r.when)}（${_remainingText(r.when)}）';
        if (r.useSnooze && r.snoozeCount > 0) {
            final String cap = r.snoozeMaxCount == null ? '' : '/${r.snoozeMaxCount! - 1}'; // 押下上限目安
            return '$base / スヌーズ${r.snoozeCount}回$cap';
        }
        return base;
    }

    static String _fmtDateTime(DateTime dt) {
        final DateTime now = DateTime.now();
        final bool isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
        final String hh = dt.hour.toString().padLeft(2, '0');
        final String mm = dt.minute.toString().padLeft(2, '0');
        if (isToday) return '今日 $hh:$mm';
        final String y = dt.year.toString();
        final String m = dt.month.toString().padLeft(2, '0');
        final String d = dt.day.toString().padLeft(2, '0');
        return '$y/$m/$d $hh:$mm';
    }

    static String _remainingText(final DateTime when) {
        final Duration diff = when.difference(DateTime.now());
        final bool overdue = diff.isNegative;
        final Duration d = diff.abs();

        final int days = d.inDays;
        final int hours = d.inHours % 24;
        final int mins = d.inMinutes % 60;

        String span;
        if (days > 0) {
            span = '${days}日${hours}時間${mins}分';
        } else if (hours > 0) {
            span = '${hours}時間${mins}分';
        } else {
            span = '${mins}分';
        }
        return overdue ? '期限超過 $span' : 'あと $span';
    }

    Future<bool?> _confirmDelete(BuildContext context) async {
        return showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                title: const Text('削除しますか？'),
                content: const Text('このリマインドを削除します。よろしいですか？'),
                actions: [
                    TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('キャンセル')),
                    FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('削除')),
                ],
            ),
        );
    }
}

/* ======= 作成/編集シート（前回のUIを流用・IDとスヌーズ基準のみ追加） ======= */

class _ReminderSheet extends StatefulWidget {
    final Reminder? initial;
    const _ReminderSheet({this.initial});
    @override
    State<_ReminderSheet> createState() => _ReminderSheetState();
}

class _ReminderSheetState extends State<_ReminderSheet> {
    final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
    final TextEditingController _titleCtl = TextEditingController();
    final TextEditingController _noteCtl = TextEditingController();
    final TextEditingController _snoozeIntervalCtl = TextEditingController(text: '5'); // 分
    final TextEditingController _snoozeMaxCtl = TextEditingController(text: '3');      // 回
    final TextEditingController _snoozeCountCtl = TextEditingController(text: '0');

    DateTime? _selectedDate;
    TimeOfDay? _selectedTime;
    bool _useSnooze = false;

    @override
    void initState() {
        super.initState();
        final init = widget.initial;
        if (init != null) {
            _titleCtl.text = init.title;
            _noteCtl.text = init.note ?? '';
            _useSnooze = init.useSnooze;
            _snoozeIntervalCtl.text = (init.snoozeIntervalMinutes ?? 5).toString();
            _snoozeMaxCtl.text = (init.snoozeMaxCount ?? 3).toString();
            _snoozeCountCtl.text = init.snoozeCount.toString();
            _selectedDate = DateTime(init.when.year, init.when.month, init.when.day);
            _selectedTime = TimeOfDay(hour: init.when.hour, minute: init.when.minute);
        }
    }

    @override
    void dispose() {
        _titleCtl.dispose();
        _noteCtl.dispose();
        _snoozeIntervalCtl.dispose();
        _snoozeMaxCtl.dispose();
        _snoozeCountCtl.dispose();
        super.dispose();
    }

    bool get _isValid {
        if (_titleCtl.text.trim().isEmpty) return false;
        if (_selectedDate == null || _selectedTime == null) return false;
        if (_useSnooze) {
            final int? interval = int.tryParse(_snoozeIntervalCtl.text);
            final int? maxCnt = int.tryParse(_snoozeMaxCtl.text);
            final int? cnt = int.tryParse(_snoozeCountCtl.text);
            if (interval == null || interval < 1) return false;
            if (maxCnt == null || maxCnt < 1) return false;
            if (cnt == null || cnt < 0) return false;
        }
        return true;
    }

    DateTime? get _mergedDateTime {
        if (_selectedDate == null || _selectedTime == null) return null;
        return DateTime(
            _selectedDate!.year,
            _selectedDate!.month,
            _selectedDate!.day,
            _selectedTime!.hour,
            _selectedTime!.minute,
        );
    }

    int _genId() => DateTime.now().millisecondsSinceEpoch.remainder(100000000); // 簡易ID

    @override
    Widget build(BuildContext context) {
        final EdgeInsets padding = MediaQuery.of(context).viewInsets + const EdgeInsets.fromLTRB(16, 12, 16, 16);
        final bool isEdit = widget.initial != null;

        return Padding(
            padding: padding,
            child: Form(
                key: _formKey,
                child: SingleChildScrollView(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                            Text(isEdit ? 'タスクを編集' : 'タスクを作成', style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 12),

                            TextFormField(
                                controller: _titleCtl,
                                decoration: const InputDecoration(
                                    labelText: 'リマインド名（必須）',
                                    border: OutlineInputBorder(),
                                ),
                                onChanged: (_) => setState(() {}),
                                validator: (v) => (v == null || v.trim().isEmpty) ? 'リマインド名を入力してください' : null,
                            ),
                            const SizedBox(height: 12),

                            TextFormField(
                                controller: _noteCtl,
                                maxLines: 3,
                                decoration: const InputDecoration(
                                    labelText: '内容（任意）',
                                    border: OutlineInputBorder(),
                                ),
                            ),
                            const SizedBox(height: 12),

                            Row(
                                children: [
                                    Expanded(
                                        child: OutlinedButton.icon(
                                            icon: const Icon(Icons.event),
                                            label: Text(
                                                _selectedDate == null
                                                    ? '日付を選択'
                                                    : '${_selectedDate!.year}/${_selectedDate!.month.toString().padLeft(2, '0')}/${_selectedDate!.day.toString().padLeft(2, '0')}',
                                            ),
                                            onPressed: () async {
                                                final now = DateTime.now();
                                                final picked = await showDatePicker(
                                                    context: context,
                                                    initialDate: _selectedDate ?? now,
                                                    firstDate: DateTime(now.year - 1),
                                                    lastDate: DateTime(now.year + 5),
                                                );
                                                if (picked != null) setState(() => _selectedDate = picked);
                                            },
                                        ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                        child: OutlinedButton.icon(
                                            icon: const Icon(Icons.schedule),
                                            label: Text(_selectedTime == null ? '時刻を選択' : _selectedTime!.format(context)),
                                            onPressed: () async {
                                                final picked = await showTimePicker(
                                                    context: context,
                                                    initialTime: _selectedTime ?? TimeOfDay.now(),
                                                );
                                                if (picked != null) setState(() => _selectedTime = picked);
                                            },
                                        ),
                                    ),
                                ],
                            ),
                            const SizedBox(height: 12),

                            CheckboxListTile(
                                value: _useSnooze,
                                onChanged: (v) => setState(() => _useSnooze = v ?? false),
                                controlAffinity: ListTileControlAffinity.leading,
                                title: const Text('スヌーズを使用する'),
                            ),

                            AnimatedCrossFade(
                                duration: const Duration(milliseconds: 200),
                                crossFadeState: _useSnooze ? CrossFadeState.showFirst : CrossFadeState.showSecond,
                                firstChild: Padding(
                                    padding: const EdgeInsets.only(top: 4, bottom: 8),
                                    child: Column(
                                        children: [
                                            Row(
                                                children: [
                                                    Expanded(
                                                        child: TextFormField(
                                                            controller: _snoozeIntervalCtl,
                                                            decoration: const InputDecoration(
                                                                labelText: '分ごとに',
                                                                border: OutlineInputBorder(),
                                                            ),
                                                            keyboardType: TextInputType.number,
                                                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                                            validator: (_) {
                                                                if (!_useSnooze) return null;
                                                                final int? v = int.tryParse(_snoozeIntervalCtl.text);
                                                                if (v == null || v < 1) return '1以上を入力';
                                                                return null;
                                                            },
                                                        ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                        child: TextFormField(
                                                            controller: _snoozeMaxCtl,
                                                            decoration: const InputDecoration(
                                                                labelText: '最大回数（初回含む）',
                                                                border: OutlineInputBorder(),
                                                            ),
                                                            keyboardType: TextInputType.number,
                                                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                                            validator: (_) {
                                                                if (!_useSnooze) return null;
                                                                final int? v = int.tryParse(_snoozeMaxCtl.text);
                                                                if (v == null || v < 1) return '1以上を入力';
                                                                return null;
                                                            },
                                                        ),
                                                    ),
                                                ],
                                            ),
                                            const SizedBox(height: 8),
                                            TextFormField(
                                                controller: _snoozeCountCtl,
                                                decoration: const InputDecoration(
                                                    labelText: 'スヌーズ押下回数（表示用）',
                                                    border: OutlineInputBorder(),
                                                ),
                                                keyboardType: TextInputType.number,
                                                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                                validator: (_) {
                                                    final int? v = int.tryParse(_snoozeCountCtl.text);
                                                    if (v == null || v < 0) return '0以上を入力';
                                                    return null;
                                                },
                                            ),
                                        ],
                                    ),
                                ),
                                secondChild: const SizedBox.shrink(),
                            ),

                            const SizedBox(height: 8),

                            FilledButton(
                                onPressed: _isValid
                                    ? () {
                                        if (!_formKey.currentState!.validate()) {
                                            setState(() {});
                                            return;
                                        }
                                        final when = _mergedDateTime!;
                                        final baseId = widget.initial?.id ?? _genId();

                                        final result = (widget.initial == null)
                                            ? Reminder(
                                                id: baseId,
                                                title: _titleCtl.text.trim(),
                                                note: _noteCtl.text.trim().isEmpty ? null : _noteCtl.text.trim(),
                                                when: when,
                                                useSnooze: _useSnooze,
                                                snoozeIntervalMinutes: _useSnooze ? int.parse(_snoozeIntervalCtl.text) : null,
                                                snoozeMaxCount: _useSnooze ? int.parse(_snoozeMaxCtl.text) : null,
                                                snoozeCount: int.tryParse(_snoozeCountCtl.text) ?? 0,
                                            )
                                            : widget.initial!.copyWith(
                                                title: _titleCtl.text.trim(),
                                                note: _noteCtl.text.trim().isEmpty ? null : _noteCtl.text.trim(),
                                                when: when,
                                                useSnooze: _useSnooze,
                                                snoozeIntervalMinutes: _useSnooze ? int.parse(_snoozeIntervalCtl.text) : null,
                                                snoozeMaxCount: _useSnooze ? int.parse(_snoozeMaxCtl.text) : null,
                                                snoozeCount: int.tryParse(_snoozeCountCtl.text) ?? 0,
                                            );

                                        Navigator.of(context).pop(result);
                                    }
                                    : null,
                                child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    child: Text(widget.initial == null ? '作成' : '保存'),
                                ),
                            ),
                            const SizedBox(height: 8),
                            TextButton(
                                onPressed: () => Navigator.of(context).maybePop(),
                                child: const Text('キャンセル'),
                            ),
                        ],
                    ),
                ),
            ),
        );
    }
}

class _EmptyList extends StatelessWidget {
    const _EmptyList();
    @override
    Widget build(BuildContext context) {
        return Center(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                    const Icon(Icons.event_note, size: 48),
                    const SizedBox(height: 8),
                    Text('次のリマインドはありません', style: Theme.of(context).textTheme.bodyMedium),
                ],
            ),
        );
    }
}

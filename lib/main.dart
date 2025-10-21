import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const MyApp());

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

/// リマインドの簡易モデル
class Reminder {
    final String title;
    final String? note;
    final DateTime when;
    final bool useSnooze;
    final int? snoozeIntervalMinutes;
    final int? snoozeMaxCount;
    final int snoozeCount; // スヌーズ押下回数
    final bool isDone;

    const Reminder({
        required this.title,
        required this.when,
        this.note,
        this.useSnooze = false,
        this.snoozeIntervalMinutes,
        this.snoozeMaxCount,
        this.snoozeCount = 0,
        this.isDone = false,
    });

    Reminder copyWith({
        String? title,
        String? note,
        DateTime? when,
        bool? useSnooze,
        int? snoozeIntervalMinutes,
        int? snoozeMaxCount,
        int? snoozeCount,
        bool? isDone,
    }) {
        return Reminder(
            title: title ?? this.title,
            when: when ?? this.when,
            note: note ?? this.note,
            useSnooze: useSnooze ?? this.useSnooze,
            snoozeIntervalMinutes: snoozeIntervalMinutes ?? this.snoozeIntervalMinutes,
            snoozeMaxCount: snoozeMaxCount ?? this.snoozeMaxCount,
            snoozeCount: snoozeCount ?? this.snoozeCount,
            isDone: isDone ?? this.isDone,
        );
    }
}

/// 起動直後の画面
class HomeScreen extends StatefulWidget {
    const HomeScreen({super.key});
    @override
    State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
    final List<Reminder> _reminders = <Reminder>[
        Reminder(title: 'ミーティング資料送付', when: DateTime.now().add(const Duration(hours: 2)), useSnooze: true, snoozeCount: 0, snoozeIntervalMinutes: 5, snoozeMaxCount: 3),
        Reminder(title: '牛乳を買う', when: DateTime.now().add(const Duration(minutes: 45))), // 1時間未満→注意色
        Reminder(title: '定例MTG', when: DateTime.now().add(const Duration(days: 1, hours: 1))),
        Reminder(title: '期限過ぎタスク例', when: DateTime.now().subtract(const Duration(minutes: 10))), // 期限超過→警告色
    ];

    @override
    Widget build(BuildContext context) {
        final List<Reminder> upcoming = List<Reminder>.from(_reminders)
            ..sort((a, b) => a.when.compareTo(b.when));

        return Scaffold(
            appBar: AppBar(title: const Text('リマインダー'), centerTitle: true),
            body: SafeArea(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                            // 登録ボタン（大きめ）
                            SizedBox(
                                height: 64,
                                child: FilledButton.icon(
                                    icon: const Icon(Icons.add, size: 24),
                                    onPressed: () async {
                                        final Reminder? created = await _openReminderSheet(context);
                                        if (created != null) {
                                            setState(() => _reminders.add(created));
                                            ScaffoldMessenger.of(context).showSnackBar(
                                                const SnackBar(content: Text('リマインドを作成しました')),
                                            );
                                        }
                                    },
                                    label: const Text('登録', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                                ),
                            ),
                            const SizedBox(height: 20),

                            // 見出し
                            Row(
                                children: [
                                    const Text('次のリマインド', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                                    const SizedBox(width: 8),
                                    Badge(label: Text('${upcoming.length}')),
                                ],
                            ),
                            const SizedBox(height: 8),

                            // リスト（右端：編集🖊️・削除🗑️）
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
                                                color: tileColor, // 状態に応じた色
                                                child: ListTile(
                                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                                    leading: Icon(r.isDone ? Icons.check_circle : Icons.alarm),
                                                    title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                                    subtitle: Text(subtitleText, maxLines: 2),
                                                    // 右端アクション（編集・削除）
                                                    trailing: Row(
                                                        mainAxisSize: MainAxisSize.min,
                                                        children: [
                                                            IconButton(
                                                                tooltip: '編集',
                                                                icon: const Icon(Icons.edit),
                                                                onPressed: () async {
                                                                    final int originalIdx = _reminders.indexOf(r);
                                                                    final Reminder? edited = await _openReminderSheet(context, initial: r);
                                                                    if (edited != null) {
                                                                        setState(() => _reminders[originalIdx] = edited);
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
                                                                        setState(() => _reminders.remove(r));
                                                                        ScaffoldMessenger.of(context).showSnackBar(
                                                                            const SnackBar(content: Text('リマインドを削除しました')),
                                                                        );
                                                                    }
                                                                },
                                                            ),
                                                        ],
                                                    ),
                                                    onTap: () async {
                                                        // タップでも編集可（好みで無効化してもOK）
                                                        final int originalIdx = _reminders.indexOf(r);
                                                        final Reminder? edited = await _openReminderSheet(context, initial: r);
                                                        if (edited != null) {
                                                            setState(() => _reminders[originalIdx] = edited);
                                                            ScaffoldMessenger.of(context).showSnackBar(
                                                                const SnackBar(content: Text('リマインドを更新しました')),
                                                            );
                                                        }
                                                    },
                                                ),
                                            );
                                        },
                                    ),
                            ),
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

        // 警告（赤系）：期限超過 or スヌーズ中
        if (overdue || snoozing) {
            return Colors.red.withOpacity(0.12); // うっすら赤
        }
        // 注意（黄系）：1時間未満
        if (warningSoon) {
            return Colors.amber.withOpacity(0.16); // うっすら黄
        }
        // 通常
        return null;
    }

    /// サブタイトル表示：「YYYY/MM/DD HH:mm（あとX）」＋スヌーズ回数
    String _subtitleFor(Reminder r) {
        final String base = '${_fmtDateTime(r.when)}（${_remainingText(r.when)}）';
        if (r.snoozeCount > 0) {
            return '$base / スヌーズ${r.snoozeCount}回';
        }
        return base;
    }

    /// 作成/編集ポップアップ（大型モーダル）
    Future<Reminder?> _openReminderSheet(BuildContext context, {Reminder? initial}) async {
        return await showModalBottomSheet<Reminder>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            showDragHandle: true,
            builder: (_) => _ReminderSheet(initial: initial),
        );
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

/// 作成/編集シート本体
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
    final TextEditingController _snoozeCountCtl = TextEditingController(text: '0');    // 回数表示・編集可

    DateTime? _selectedDate;
    TimeOfDay? _selectedTime;
    bool _useSnooze = false;

    @override
    void initState() {
        super.initState();
        final Reminder? init = widget.initial;
        if (init != null) {
            _titleCtl.text = init.title;
            _noteCtl.text = init.note ?? '';
            _useSnooze = init.useSnooze;
            if (init.snoozeIntervalMinutes != null) {
                _snoozeIntervalCtl.text = init.snoozeIntervalMinutes.toString();
            }
            if (init.snoozeMaxCount != null) {
                _snoozeMaxCtl.text = init.snoozeMaxCount.toString();
            }
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
            if (interval == null || interval < 1) return false;
            if (maxCnt == null || maxCnt < 1) return false;
            final int? cnt = int.tryParse(_snoozeCountCtl.text);
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

                            // リマインド名（必須）
                            TextFormField(
                                controller: _titleCtl,
                                decoration: const InputDecoration(
                                    labelText: 'リマインド名（必須）',
                                    hintText: '例：資料送付、買い物、タスク名など',
                                    border: OutlineInputBorder(),
                                ),
                                textInputAction: TextInputAction.next,
                                onChanged: (_) => setState(() {}),
                                validator: (v) => (v == null || v.trim().isEmpty) ? 'リマインド名を入力してください' : null,
                            ),
                            const SizedBox(height: 12),

                            // 内容（任意）
                            TextFormField(
                                controller: _noteCtl,
                                maxLines: 3,
                                decoration: const InputDecoration(
                                    labelText: '内容（任意）',
                                    hintText: '詳細メモなど',
                                    border: OutlineInputBorder(),
                                ),
                                textInputAction: TextInputAction.newline,
                            ),
                            const SizedBox(height: 12),

                            // 日時（必須）
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
                                                final DateTime now = DateTime.now();
                                                final DateTime first = DateTime(now.year - 1);
                                                final DateTime last = DateTime(now.year + 5);
                                                final DateTime? picked = await showDatePicker(
                                                    context: context,
                                                    initialDate: _selectedDate ?? now,
                                                    firstDate: first,
                                                    lastDate: last,
                                                );
                                                if (picked != null) {
                                                    setState(() => _selectedDate = picked);
                                                }
                                            },
                                        ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                        child: OutlinedButton.icon(
                                            icon: const Icon(Icons.schedule),
                                            label: Text(
                                                _selectedTime == null
                                                    ? '時刻を選択'
                                                    : _selectedTime!.format(context),
                                            ),
                                            onPressed: () async {
                                                final TimeOfDay now = TimeOfDay.now();
                                                final TimeOfDay? picked = await showTimePicker(
                                                    context: context,
                                                    initialTime: _selectedTime ?? now,
                                                );
                                                if (picked != null) {
                                                    setState(() => _selectedTime = picked);
                                                }
                                            },
                                        ),
                                    ),
                                ],
                            ),
                            const SizedBox(height: 12),

                            // スヌーズ
                            CheckboxListTile(
                                value: _useSnooze,
                                onChanged: (v) => setState(() => _useSnooze = v ?? false),
                                controlAffinity: ListTileControlAffinity.leading,
                                title: const Text('スヌーズを使用する'),
                                subtitle: const Text('必要な場合はチェックを入れて間隔と回数を設定'),
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
                                                    SizedBox(
                                                        width: 120,
                                                        child: TextFormField(
                                                            controller: _snoozeIntervalCtl,
                                                            decoration: const InputDecoration(
                                                                labelText: '分ごとに',
                                                                border: OutlineInputBorder(),
                                                            ),
                                                            keyboardType: TextInputType.number,
                                                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                                            onChanged: (_) => setState(() {}),
                                                            validator: (_) {
                                                                if (!_useSnooze) return null;
                                                                final int? v = int.tryParse(_snoozeIntervalCtl.text);
                                                                if (v == null || v < 1) return '1以上を入力';
                                                                return null;
                                                            },
                                                        ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    const Text('最大'),
                                                    const SizedBox(width: 8),
                                                    SizedBox(
                                                        width: 120,
                                                        child: TextFormField(
                                                            controller: _snoozeMaxCtl,
                                                            decoration: const InputDecoration(
                                                                labelText: '回',
                                                                border: OutlineInputBorder(),
                                                            ),
                                                            keyboardType: TextInputType.number,
                                                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                                            onChanged: (_) => setState(() {}),
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
                                            // スヌーズ回数（表示・編集可能）
                                            Row(
                                                children: [
                                                    Expanded(
                                                        child: TextFormField(
                                                            controller: _snoozeCountCtl,
                                                            decoration: const InputDecoration(
                                                                labelText: 'スヌーズ回数',
                                                                hintText: '0以上の整数',
                                                                border: OutlineInputBorder(),
                                                            ),
                                                            keyboardType: TextInputType.number,
                                                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                                            validator: (_) {
                                                                if (!_useSnooze) return null;
                                                                final int? v = int.tryParse(_snoozeCountCtl.text);
                                                                if (v == null || v < 0) return '0以上を入力';
                                                                return null;
                                                            },
                                                        ),
                                                    ),
                                                ],
                                            ),
                                        ],
                                    ),
                                ),
                                secondChild: const SizedBox.shrink(),
                            ),

                            const SizedBox(height: 8),

                            // 作成/保存ボタン
                            FilledButton(
                                onPressed: _isValid
                                    ? () {
                                        if (!_formKey.currentState!.validate()) {
                                            setState(() {});
                                            return;
                                        }
                                        final DateTime? when = _mergedDateTime;
                                        if (when == null) return;

                                        final int parsedSnoozeCount = int.tryParse(_snoozeCountCtl.text) ?? 0;

                                        final Reminder result = (widget.initial == null)
                                            ? Reminder(
                                                title: _titleCtl.text.trim(),
                                                note: _noteCtl.text.trim().isEmpty ? null : _noteCtl.text.trim(),
                                                when: when,
                                                useSnooze: _useSnooze,
                                                snoozeIntervalMinutes: _useSnooze ? int.parse(_snoozeIntervalCtl.text) : null,
                                                snoozeMaxCount: _useSnooze ? int.parse(_snoozeMaxCtl.text) : null,
                                                snoozeCount: _useSnooze ? parsedSnoozeCount : 0,
                                            )
                                            : widget.initial!.copyWith(
                                                title: _titleCtl.text.trim(),
                                                note: _noteCtl.text.trim().isEmpty ? null : _noteCtl.text.trim(),
                                                when: when,
                                                useSnooze: _useSnooze,
                                                snoozeIntervalMinutes: _useSnooze ? int.parse(_snoozeIntervalCtl.text) : null,
                                                snoozeMaxCount: _useSnooze ? int.parse(_snoozeMaxCtl.text) : null,
                                                snoozeCount: _useSnooze ? parsedSnoozeCount : 0,
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

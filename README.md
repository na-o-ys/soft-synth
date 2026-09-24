# soft-synth

MIDI 鍵盤をつなぐだけで、やわらかいシンセ音が鳴る常駐デーモン（macOS）。
GarageBand を起動せずに弾きたいとき用。

- サイン波ベースの加算合成 + 軽い FDN リバーブ（耳当たり重視）
- 32 音ポリフォニー、サステインペダル（CC64）対応
- USB / Bluetooth MIDI 鍵盤に自動接続（BLE MIDI も Audio MIDI 設定での手動接続は不要）
- 音色プリセットとノブ・パッド・ストリップの割り当てを JSON の設定ファイルで定義（保存すると自動で再読み込み）
- 待機時 CPU 約 0.5%、メモリ約 7MB

## 使い方

```sh
make install                              # ~/.local/bin に入れて LaunchAgent 登録（ログイン時に自動起動）
make install CONFIG=examples/smk25ii.json # 初回のみ、設定ファイルの雛形を選べる
make monitor    # 鍵盤から届く MIDI メッセージを表示（割り当てを作るとき用）
make demo       # 鍵盤なしで和音を鳴らして確認
make log        # ログを見る
make restart    # 再起動
make uninstall  # 削除
```

設定ファイルは `~/.config/soft-synth/config.json`（`--config PATH` で変更可）。
`make install` は既存の設定ファイルを上書きしない。書き換えて保存すれば 1 秒以内に反映される。
JSON に誤りがあるとログにエラーを出し、直前の設定のまま動き続ける。

## 設定ファイル

```jsonc
{
  "preset": "soft-piano",          // 起動時のプリセット
  "params": {"volume": 0.8},       // 全プリセット共通の値
  "presets": [ ... ],              // 音色プリセット（順番が nextPreset / prevPreset の順）
  "controls": [ ... ],             // MIDI メッセージの割り当て
  "logMIDI": false                 // true で受信メッセージをすべてログに出す
}
```

### パラメータ

| 名前 | 意味 | 既定値 |
|---|---|---|
| `volume` | 全体の音量 | 0.8 |
| `attack` / `decay` / `release` | エンベロープの時間（秒）。decay は sustain へ向かう時定数 | 0.008 / 1.6 / 0.28 |
| `sustain` | 押し続けたときの音量 0–1 | 0.3 |
| `brightness` | 倍音（ratio が 1 以外の partial）の量の倍率 | 1 |
| `chorus` / `detune` | 少しずらした基音の量 / ずらす量（cent） | 0.5 / 4 |
| `reverb` / `reverbSize` / `reverbDamp` | 残響の量 / 長さ（0–0.97）/ 暗さ（0–1） | 0.22 / 0.8 / 0.65 |
| `vibrato` / `vibratoRate` | ビブラートの深さ（半音）/ 速さ（Hz） | 0 / 5 |
| `velocity` | ベロシティ感度 0–1 | 0.8 |
| `transpose` | 移調（半音） | 0 |
| `bend` | ピッチベンド（半音） | 0 |

`volume`・`transpose`・`bend` は演奏中の状態としてプリセットを切り替えても保持される。
それ以外はプリセット切替時に「既定値 ← `params` ← プリセット」で決まり直す。

### プリセット

```json
{"name": "e-piano", "attack": 0.004, "sustain": 0.15,
 "partials": [
   {"ratio": 1, "level": 1},
   {"ratio": 2, "level": 0.05, "velocity": 0.3, "decay": 0.4}
 ]}
```

`partials`（最大 8 個）はサイン波の倍音構成。`ratio` は基音に対する周波数比、`level` は音量、
`velocity` は強く弾いたときに足される音量、`decay` はその倍音だけが減衰する時定数（秒、0 で減衰なし）。
省略時は soft-piano 相当の構成になる。

### controls

各要素は「どのメッセージで」＋「何をするか」。`channel`（1–16）を省くと全チャンネルに一致する。
割り当てたメッセージは音を鳴らさない（パッドをプリセット切替にした場合など）。

入力: `{"cc": 番号}` / `{"note": 番号}` / `{"pitchBend": true}`

連続値でパラメータを動かす（ノブ・スライダー向け）:

```json
{"cc": 31, "param": "release", "min": 0.05, "max": 4, "curve": "exp"}
{"pitchBend": true, "param": "transpose", "min": -12, "max": 12, "step": 1}
```

`curve: "exp"` は時間系のパラメータ向け（min, max > 0）。`step` を指定すると値を刻む。
note に割り当てると押している間 max、離すと min になる。

押したときのアクション（パッド・ボタン向け）:

| action | 追加フィールド | 動作 |
|---|---|---|
| `preset` | `preset` | 指定プリセットに切り替え |
| `nextPreset` / `prevPreset` | | 次 / 前のプリセット |
| `set` | `param`, `value` | 値を設定 |
| `add` | `param`, `value`, 任意で `min`, `max` | 値を加算（範囲内に収める） |
| `toggle` | `param`, `values: [off, on]` | 2 値を切り替え |
| `panic` | | 鳴っている音をすべて止める |

割り当てのない note / CC64（サステイン）/ CC120・123（全消音）は通常の MIDI として扱う。

### 例

- [config.example.json](config.example.json): 一般的な鍵盤向け（ピッチベンド、モジュレーション、GM 標準の CC 7/72/73/74/91/93）
- [examples/smk25ii.json](examples/smk25ii.json): M-VAVE SMK-25 II 向け
  - ノブ 1–8（CC 30–37）: volume / brightness / attack / decay / sustain / release / chorus / reverb
  - PITCH ストリップ: transpose ±12、MOD ストリップ: vibrato
  - パッド上段（note 40–43, 48–51）: プリセット選択、下段（36–39, 44–46）: オクターブ・半音移調、移調リセット、ビブラート切替、全消音
  - 本体の仕様で下段 8 番目のパッドは上段 4 番目と同じ note 43 を送るため、どちらも nextPreset にしている

自分の鍵盤用の設定は `make monitor` でノブやパッドを触り、表示された番号を controls に書けばよい。

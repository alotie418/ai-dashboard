import XCTest
@testable import SoloLedger
import SoloLedgerCore

/// Stage 2a-3 — the 97 `legacy.convert.*` strings the conversion wizard will need, landed in
/// all six languages and reachable by nothing.
///
/// ## What this file is for, given how much the tree already guards
///
/// Six-locale KEY parity, placeholder parity, duplicate keys and raw-key leaks are already
/// enforced over the whole universe by `MigrationCopyParityTests`, and the banned-wording scan
/// by `LocalizationWordingGuardTests`. None of them is repeated here. What none of them can see
/// is the four things this stage can actually get wrong:
///
///  * **A miscount.** Key parity is satisfied by all six locales missing the same key. Only an
///    absolute count catches "the adjudicated table said 97 and 96 landed".
///  * **An unmapped enum case.** `LegacyRowIssue` has seventeen cases and each needs its own
///    sentence; a copy set that is internally consistent but one case short is invisible to
///    every parity check in the tree.
///  * **Reachability.** 2a-3's whole contract is that the copy lands DORMANT — the wizard, the
///    routing and the error mapping are 2a-4. Nothing else in the tree asserts that a `.strings`
///    key is unused.
///  * **Leaking the machine's own words.** `LegacyConversionFailure.description` is English
///    prose with interpolated ids and SQLite messages in it. `AppModel` surfaces a dozen other
///    failures as `actionError = "\(error)"` today, so the shape is already in the codebase and
///    the copy has to be provably a different thing.
///
/// ## The guard word lists are READ, not copied
///
/// ``testT5NewCopyHasZeroBannedWordingHits`` parses the three tables out of
/// `LocalizationWordingGuardTests.swift` rather than restating them. That file lives in the
/// SwiftPM test target and cannot be imported from here, and a hand-copied vocabulary would be
/// a fork that goes stale in exactly the direction that matters — the guard grows a word, this
/// file keeps passing. Parsing keeps one source of truth and makes a drifted list a failure
/// here as well.
final class LegacyConversionCopyTests: XCTestCase {

    private let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    /// Every placeholder token the adjudicated copy is allowed to use, anywhere.
    ///
    /// `{issued}` / `{pending}` / `{na}` are the three that were added when the status
    /// disclosure was reworked: naming the target labels literally put 已开票 — a `filingWords`
    /// pattern — into a `.strings` value, and the only sanction for that pattern is bound to
    /// `invoice.issued`, by triple. Interpolating from that key instead keeps the word where it
    /// is already sanctioned. See ``testTheStatusDisclosureInterpolatesFromTheInvoiceStatusKeys``.
    private static let allowedPlaceholders: Set<String> = [
        "{count}", "{year}", "{codes}", "{currency}", "{path}",
        "{issued}", "{pending}", "{na}",
    ]

    /// A substitution that supplies EVERY allowed token, so a fully-rendered string may not
    /// contain a brace for any reason.
    private static let everyToken: [String: String] = [
        "count": "3", "year": "2024", "codes": "EUR, USD", "currency": "CNY",
        "path": "/Users/x/Backups/pre-convert-20260802", "issued": "ISSUED",
        "pending": "PENDING", "na": "NA",
    ]

    // ===== T7 table (the five reachable legacy.* strings, as they stand after 2a-4) =====
    private static let reachableLegacyCopy: [String: [String: String]] = [
        "legacy.notice.title": [
            "zh-Hans": "此账本有 {count} 条旧版销售 / 采购记录",
            "zh-Hant": "此帳本有 {count} 筆舊版銷售 / 採購紀錄",
            "en": "Legacy sales / purchase records in this ledger: {count}",
            "ja": "この台帳には旧版の売上・仕入記録が {count} 件あります",
            "ko": "이 장부에는 이전 버전의 매출·매입 기록이 {count}건 있습니다",
            "fr": "Enregistrements de ventes / achats hérités dans cette comptabilité : {count}",
        ],
        "legacy.notice.message": [
            "zh-Hans": "它们完整保存在账本文件中，没有丢失。本 App 目前只显示「流水」，因此这里看不到它们。现在可以先查看把其中符合条件的旧记录转换为流水会做什么，确认后再开始；在你确认之前不会写入任何内容。",
            "zh-Hant": "它們完整保存在帳本檔案中，沒有遺失。本 App 目前只顯示「流水」，因此這裡看不到它們。現在可以先查看把其中符合條件的舊紀錄轉換為流水會做什麼，確認後再開始；在你確認之前不會寫入任何內容。",
            "en": "They are stored intact in the ledger file — nothing was lost. This app currently shows only transactions, so they are not listed here. You can now review what converting the eligible legacy records into transactions would do, and start only after you confirm; nothing is written before you do.",
            "ja": "これらは台帳ファイルにそのまま保存されており、失われていません。本アプリは現在「取引」のみを表示するため、ここには表示されません。条件を満たす旧記録を取引へ変換すると何が起きるかは、先に確認できます。変換は確認後に開始され、それまで書き込みは行われません。",
            "ko": "해당 기록은 장부 파일에 그대로 저장되어 있으며 사라지지 않았습니다. 이 앱은 현재 ‘거래’만 표시하므로 여기에는 나타나지 않습니다. 조건을 충족하는 이전 기록을 거래로 변환하면 무엇이 달라지는지 먼저 확인할 수 있습니다. 변환은 확인한 뒤에 시작되며 그 전에는 아무것도 기록되지 않습니다.",
            "fr": "Ils sont conservés intacts dans le fichier de comptabilité — rien n'a été perdu. Cette app n'affiche pour l'instant que les écritures, ils ne sont donc pas listés ici. Vous pouvez maintenant voir ce que donnerait la conversion des enregistrements hérités éligibles en écritures ; elle ne démarre qu'après votre confirmation, et rien n'est écrit avant.",
        ],
        "legacy.banner": [
            "zh-Hans": "另有 {count} 条旧版销售 / 采购记录未在此显示。",
            "zh-Hant": "另有 {count} 筆舊版銷售 / 採購紀錄未在此顯示。",
            "en": "Legacy sales / purchase records not shown here: {count}",
            "ja": "旧版の売上・仕入記録が {count} 件、ここには表示されていません。",
            "ko": "이전 버전의 매출·매입 기록 {count}건은 여기에 표시되지 않습니다.",
            "fr": "Enregistrements de ventes / achats hérités non affichés ici : {count}",
        ],
        "legacy.other.title": [
            "zh-Hans": "此账本包含本 App 尚未显示的记录",
            "zh-Hant": "此帳本包含本 App 尚未顯示的紀錄",
            "en": "This ledger holds records this app does not show yet",
            "ja": "この台帳には本アプリがまだ表示していない記録があります",
            "ko": "이 장부에는 이 앱이 아직 표시하지 않는 기록이 있습니다",
            "fr": "Cette comptabilité contient des enregistrements que cette app n'affiche pas encore",
        ],
        // The product example left this sentence in 2b-A4, when the products page landed: an
        // example of what the app does NOT show cannot be a thing it shows. Invoices and fixed
        // assets are still hidden, so the sentence keeps its point and loses only that item.
        "legacy.other.message": [
            "zh-Hans": "账本文件中存在发票、固定资产等类型的记录。它们完整保存在文件中，没有丢失；本 App 目前只显示「流水」。",
            "zh-Hant": "帳本檔案中存在發票、固定資產等類型的紀錄。它們完整保存在檔案中，沒有遺失；本 App 目前只顯示「流水」。",
            "en": "The file contains records such as invoices and fixed assets. They are stored intact — nothing was lost. This app currently shows only transactions.",
            "ja": "台帳ファイルには請求書・固定資産などの記録が保存されています。これらはそのまま保存されており、失われていません。本アプリは現在「取引」のみを表示します。",
            "ko": "장부 파일에는 청구서·고정자산 등의 기록이 저장되어 있습니다. 그대로 보관되어 있으며 사라지지 않았습니다. 이 앱은 현재 '거래'만 표시합니다.",
            "fr": "Le fichier contient des enregistrements tels que factures et immobilisations. Ils sont conservés intacts — rien n'a été perdu. Cette app n'affiche pour l'instant que les écritures.",
        ],
    ]

    // ===== T12 table (the 9 adjudicated high-risk keys) =====
    private static let adjudicatedHighRiskCopy: [String: [String: String]] = [
        "legacy.convert.grade.convertible.note": [
            "zh-Hans": "这些记录可以转换，不需要猜测任何值，也不会静默丢弃转换所依赖的源数据。旧记录本身仍完整保存在账本文件中。",
            "zh-Hant": "這些紀錄可以轉換，不需要猜測任何值，也不會默默捨棄轉換所依賴的來源資料。舊紀錄本身仍完整保存在帳本檔案中。",
            "en": "These records can be converted without guessing a value or silently dropping source data the conversion relies on. The legacy records themselves remain intact in the ledger file.",
            "ja": "これらの記録は、値を推測したり、変換に必要な元データを黙って捨てたりせずに変換できます。旧記録そのものは台帳ファイルにそのまま残ります。",
            "ko": "이 기록은 값을 추측하거나 변환에 필요한 원본 데이터를 조용히 버리지 않고 변환할 수 있습니다. 이전 기록 자체는 장부 파일에 그대로 남습니다.",
            "fr": "Ces enregistrements peuvent être convertis sans deviner de valeur ni écarter silencieusement les données source nécessaires à la conversion. Les enregistrements hérités eux-mêmes restent intacts dans le fichier de comptabilité.",
        ],
        "legacy.convert.grade.needsAdjudication.note": [
            "zh-Hans": "这些记录含有本 App 无法可靠带入流水的内容，因此不会被转换。你可以继续转换其余可转换记录，或取消本次转换。",
            "zh-Hant": "這些紀錄含有本 App 無法可靠帶入流水的內容，因此不會被轉換。你可以繼續轉換其餘可轉換紀錄，或取消本次轉換。",
            "en": "These records contain values this app cannot carry into transactions reliably, so they will not be converted. You can continue with the remaining convertible records, or cancel the conversion.",
            "ja": "これらの記録には、本アプリが取引へ確実に引き継げない内容があるため、変換されません。残りの変換可能な記録を変換するか、変換を取り消すことができます。",
            "ko": "이 기록에는 이 앱이 거래로 신뢰성 있게 옮길 수 없는 내용이 있으므로 변환되지 않습니다. 나머지 변환 가능한 기록을 계속 변환하거나 변환을 취소할 수 있습니다.",
            "fr": "Ces enregistrements contiennent des valeurs que cette app ne peut pas reporter de façon fiable dans les écritures ; ils ne seront donc pas convertis. Vous pouvez poursuivre avec les autres enregistrements convertibles, ou annuler la conversion.",
        ],
        "legacy.convert.issue.amountWithoutTaxNotANumber": [
            "zh-Hans": "不含税金额在账本里存有内容，但该内容不能作为数字读取。只有账本中确实未存此值时，转换才会按缺失保留；现有的非数字内容不能被当作空值。",
            "zh-Hant": "不含稅金額在帳本裡存有內容，但該內容不能作為數字讀取。只有帳本中確實未存此值時，轉換才會按缺失保留；現有的非數字內容不能被當作空值。",
            "en": "The amount excluding tax contains a value in the ledger, but that value cannot be read as a number. Conversion can preserve an absence only when no value is actually stored; existing non-numeric content cannot be treated as an empty field.",
            "ja": "税抜金額には値が保存されていますが、数値として読み取れません。実際に値が保存されていない場合だけ、変換は欠損のまま引き継げます。保存済みの数値でない内容を空欄として扱うことはできません。",
            "ko": "세전 금액에 값이 저장되어 있지만 숫자로 읽을 수 없습니다. 실제로 값이 저장되지 않은 경우에만 변환에서 누락 상태로 유지할 수 있습니다. 이미 저장된 숫자가 아닌 내용을 빈 값으로 처리할 수는 없습니다.",
            "fr": "Le montant hors taxe contient une valeur dans le livre, mais cette valeur ne peut pas être lue comme un nombre. La conversion ne peut conserver une absence que lorsqu’aucune valeur n’est réellement enregistrée ; un contenu non numérique existant ne peut pas être traité comme un champ vide.",
        ],
        "legacy.convert.consequence.shipping": [
            "zh-Hans": "流水没有运费栏位。旧版销售记录中的运费只会按原样保存在流水的来源记录里，不参与报表计算；如果该值非零，使用中国会计制度时，受影响年度的税前利润、所得税和净利润可能与转换前不同。",
            "zh-Hant": "流水沒有運費欄位。舊版銷售紀錄中的運費只會按原樣保存在流水的來源紀錄裡，不參與報表計算；如果該值非零，使用中國會計制度時，受影響年度的稅前利潤、所得稅和淨利潤可能與轉換前不同。",
            "en": "Transactions have no shipping-cost field. A legacy sale’s shipping cost remains verbatim only in the transaction’s source record and does not enter report calculations. If that amount is non-zero, reports for the affected year — including pre-tax profit, income tax and net profit under the China accounting profile — may differ after conversion.",
            "ja": "取引には送料欄がありません。旧版の売上記録の送料は取引のソース記録にのみそのまま残り、レポート計算には使われません。その金額がゼロでない場合、中国の会計方式では、影響を受ける年の税引前利益・所得税・純利益が変換前と異なる可能性があります。",
            "ko": "거래에는 배송비 필드가 없습니다. 이전 버전의 매출 기록에 있는 배송비는 거래의 원본 기록에만 그대로 보존되며 보고서 계산에는 사용되지 않습니다. 그 금액이 0이 아닌 경우 중국 회계 방식에서는 영향을 받는 연도의 세전 이익, 소득세 및 순이익이 변환 전과 달라질 수 있습니다.",
            "fr": "Les écritures n’ont pas de champ pour les frais de port. Les frais de port d’une vente héritée ne sont conservés tels quels que dans l’enregistrement source de l’écriture et ne participent pas aux calculs des rapports. Si ce montant n’est pas nul, les chiffres de l’année concernée — notamment le bénéfice avant impôt, l’impôt sur le revenu et le bénéfice net sous le régime comptable Chine — peuvent différer après la conversion.",
        ],
        "legacy.convert.year.secondCurrency": [
            "zh-Hans": "{year} 年：预检发现转换可能引入第二种币种（现有：{codes}）。这是保守上界；只有转换记录实际落入该年度并形成多币种时，该年度报表才会被拒绝生成。",
            "zh-Hant": "{year} 年：預檢發現轉換可能引入第二種幣別（現有：{codes}）。這是保守上界；只有轉換紀錄實際落入該年度並形成多幣別時，該年度報表才會被拒絕生成。",
            "en": "{year}: preflight found that conversion may introduce a second currency (existing: {codes}). This is a conservative upper bound; the report is refused only if converted records actually fall in this year and leave it with multiple currencies.",
            "ja": "{year}年：変換によって2つ目の通貨が加わる可能性があります（現在：{codes}）。これは保守的な上限です。変換対象の記録が実際にこの年に入り、複数通貨になる場合に限り、この年のレポートは作成できなくなります。",
            "ko": "{year}년: 변환으로 두 번째 통화가 추가될 가능성이 있습니다(현재: {codes}). 이는 보수적인 상한입니다. 변환된 기록이 실제로 이 연도에 포함되어 여러 통화가 되는 경우에만 이 연도의 보고서 생성이 거부됩니다.",
            "fr": "{year} : le contrôle préalable indique que la conversion peut introduire une seconde devise (devises actuelles : {codes}). Il s’agit d’une borne supérieure prudente ; le rapport n’est refusé que si des écritures converties appartiennent réellement à cette année et y créent plusieurs devises.",
        ],
        "legacy.convert.backup.scope": [
            "zh-Hans": "备份是磁盘上的文件夹，包含账本数据库快照及附件副本，不是账本内部的还原点。通过「设置」中的「从备份恢复…」使用它时，会用该快照替换当前账本；转换后产生的其他更改也会一并回退。",
            "zh-Hant": "備份是磁碟上的資料夾，包含帳本資料庫快照及附件副本，不是帳本內部的還原點。透過「設定」中的「從備份還原…」使用它時，會用該快照取代目前帳本；轉換後產生的其他變更也會一併回復。",
            "en": "The backup is a folder on disk containing a snapshot of the ledger database and copies of its attachments; it is not a restore point inside the ledger. Using Restore from backup… in Settings replaces the current ledger with that snapshot, so other changes made after the conversion are rolled back as well.",
            "ja": "バックアップは、台帳データベースのスナップショットと添付ファイルのコピーを含むディスク上のフォルダであり、台帳内の復元ポイントではありません。「設定」の「バックアップから復元…」で使用すると、現在の台帳がそのスナップショットに置き換わるため、変換後に行ったその他の変更も元に戻ります。",
            "ko": "백업은 장부 데이터베이스의 스냅샷과 첨부 파일 사본이 들어 있는 디스크의 폴더이며, 장부 내부의 복원 지점이 아닙니다. ‘설정’의 ‘백업에서 복원…’으로 사용하면 현재 장부가 해당 스냅샷으로 교체되므로 변환 후의 다른 변경 사항도 함께 되돌아갑니다.",
            "fr": "La sauvegarde est un dossier sur disque contenant un instantané de la base du livre et des copies de ses pièces jointes ; ce n’est pas un point de restauration interne au livre. Utiliser « Restaurer depuis une sauvegarde… » dans Réglages remplace le livre actuel par cet instantané ; les autres modifications effectuées après la conversion sont donc également annulées.",
        ],
        "legacy.convert.failed.busy": [
            "zh-Hans": "另一项操作正在写入此账本，因此本次转换已完整回滚。没有写入任何流水，账本文件未被修改。请结束占用账本的操作，然后重试。",
            "zh-Hant": "另一項操作正在寫入此帳本，因此本次轉換已完整回復。沒有寫入任何流水，帳本檔案未被修改。請結束占用帳本的操作，然後重試。",
            "en": "Another operation is writing to this ledger, so this conversion was rolled back in full. No transaction was written and the ledger file was not modified. Finish the operation using the ledger, then retry.",
            "ja": "別の処理がこの台帳に書き込んでいるため、今回の変換はすべてロールバックされました。取引は1件も書き込まれず、台帳ファイルは変更されていません。台帳を使用している処理を終了してから、もう一度お試しください。",
            "ko": "다른 작업이 이 장부에 쓰는 중이어서 이번 변환은 전체 롤백되었습니다. 거래는 하나도 기록되지 않았고 장부 파일은 변경되지 않았습니다. 장부를 사용 중인 작업을 마친 후 다시 시도하세요.",
            "fr": "Une autre opération écrit dans ce livre ; cette conversion a donc été entièrement annulée. Aucune écriture n’a été créée et le fichier du livre n’a pas été modifié. Terminez l’opération qui utilise le livre, puis réessayez.",
        ],
        "legacy.convert.consequence.statuses": [
            "zh-Hans": "空的收付状态会写为「未结」；可识别的「已结 / 部分 / 未结」保持原义。旧版发票状态中的「已开 / 已收」会写为「{issued}」，「待开 / 待收」会写为「{pending}」，其他值写为「{na}」。原始状态仍保存在流水的来源记录中。",
            "zh-Hant": "空的收付狀態會寫為「未結」；可識別的「已結 / 部分 / 未結」保持原義。舊版發票狀態中的「已開 / 已收」會寫為「{issued}」，「待開 / 待收」會寫為「{pending}」，其他值寫為「{na}」。原始狀態仍保存在流水的來源紀錄中。",
            "en": "An empty payment status is written as “Unpaid”; recognized Paid / Partial / Unpaid states keep their meaning. For legacy invoice status, “已开” / “已收” becomes “{issued}”, “待开” / “待收” becomes “{pending}”, and every other value becomes “{na}”. The original statuses remain in the transaction’s source record.",
            "ja": "空の決済状態は「未決済」として書き込まれ、認識できる「決済済み / 一部決済 / 未決済」は意味を保ちます。旧版の請求書状態は、「已开 / 已收」が「{issued}」、「待开 / 待收」が「{pending}」、それ以外が「{na}」になります。元の状態は取引のソース記録に残ります。",
            "ko": "빈 결제 상태는 ‘미결제’로 기록되며, 인식 가능한 ‘결제 완료 / 부분 결제 / 미결제’ 상태는 의미가 유지됩니다. 이전 버전의 청구서 상태는 ‘已开 / 已收’가 ‘{issued}’, ‘待开 / 待收’가 ‘{pending}’, 그 밖의 값은 ‘{na}’로 기록됩니다. 원래 상태는 거래의 원본 기록에 남습니다.",
            "fr": "Un état de règlement vide est écrit comme « Non réglé » ; les états reconnus « Réglé / Partiel / Non réglé » conservent leur sens. Pour l’état de facture hérité, « 已开 / 已收 » devient « {issued} », « 待开 / 待收 » devient « {pending} » et toute autre valeur devient « {na} ». Les états d’origine restent dans l’enregistrement source de l’écriture.",
        ],
        "legacy.convert.consequence.sourceRecord": [
            "zh-Hans": "每条新流水使用新的 ID；旧版 ID、原始创建时间、原始发票与收付状态，以及说明所依据的数量、单价和运费，保存在流水的来源记录中。不能安全显示的二进制值不会写进说明；报表不读取这些来源字段。",
            "zh-Hant": "每筆新流水使用新的 ID；舊版 ID、原始建立時間、原始發票與收付狀態，以及說明所依據的數量、單價和運費，保存在流水的來源紀錄中。不能安全顯示的二進位值不會寫進說明；報表不讀取這些來源欄位。",
            "en": "Each new transaction uses a new ID. The legacy ID, original creation time, original invoice and payment statuses, and the quantity, unit price and shipping cost used for the description remain in the transaction’s source record. Binary values that cannot be displayed safely are not written into the description; reports do not read these source fields.",
            "ja": "新しい取引にはそれぞれ新しい ID が使われます。旧版 ID、元の作成時刻、元の請求書・決済状態、説明に使われる数量・単価・送料は、取引のソース記録に残ります。安全に表示できないバイナリ値は説明には書き込まれず、レポートはこれらのソース項目を読みません。",
            "ko": "각 새 거래에는 새 ID가 사용됩니다. 이전 버전의 ID, 원래 생성 시각, 원래 청구서 및 결제 상태, 그리고 설명에 사용된 수량·단가·배송비는 거래의 원본 기록에 남습니다. 안전하게 표시할 수 없는 이진 값은 설명에 기록되지 않으며 보고서는 이러한 원본 필드를 읽지 않습니다.",
            "fr": "Chaque nouvelle écriture reçoit un nouvel identifiant. L’identifiant hérité, l’heure de création d’origine, les états d’origine de facture et de règlement, ainsi que les quantités, prix unitaires et frais de port utilisés pour la description, sont conservés dans l’enregistrement source de l’écriture. Les valeurs binaires qui ne peuvent pas être affichées sans risque ne sont pas écrites dans la description ; les rapports ne lisent pas ces champs source.",
        ],
    ]

    // ===== the 97 keys, in adjudicated group order =====
    static let conversionCopyKeys: [String] = [
        // A 入口：CTA 与一句话说明（2 键）
        "legacy.convert.cta",
        "legacy.convert.cta.hint",
        // B 向导框架：标题、开场、确认按钮（3 键；取消复用 common.cancel）
        "legacy.convert.title",
        "legacy.convert.intro",
        "legacy.convert.action.convert",
        // C 预检阻断：5 个 blocker 的标题+正文，及账本原文标签（11 键）
        "legacy.convert.blocked.accountingLocaleNotConfigured.title",
        "legacy.convert.blocked.accountingLocaleNotConfigured.body",
        "legacy.convert.blocked.accountingLocaleInvalid.title",
        "legacy.convert.blocked.accountingLocaleInvalid.body",
        "legacy.convert.blocked.currencyNotConfigured.title",
        "legacy.convert.blocked.currencyNotConfigured.body",
        "legacy.convert.blocked.currencyInvalid.title",
        "legacy.convert.blocked.currencyInvalid.body",
        "legacy.convert.blocked.currencyNotStorableVerbatim.title",
        "legacy.convert.blocked.currencyNotStorableVerbatim.body",
        "legacy.convert.storedText.label",
        // D 计划摘要：三档分级、计数与空态（9 键）
        "legacy.convert.summary.title",
        "legacy.convert.grade.convertible",
        "legacy.convert.grade.convertible.note",
        "legacy.convert.grade.needsAdjudication",
        "legacy.convert.grade.needsAdjudication.note",
        "legacy.convert.grade.unconvertible",
        "legacy.convert.grade.unconvertible.note",
        "legacy.convert.nothingToConvert.title",
        "legacy.convert.nothingToConvert.message",
        // E 逐行清单：区块标题、四个列头、两个来源表名、两个缺值占位、17 条问题（26 键）
        "legacy.convert.rows.title",
        "legacy.convert.row.col.table",
        "legacy.convert.row.col.id",
        "legacy.convert.row.col.storedDate",
        "legacy.convert.row.col.issues",
        "legacy.convert.table.sales",
        "legacy.convert.table.purchases",
        "legacy.convert.row.idUnreadable",
        "legacy.convert.row.storedDateAbsent",
        "legacy.convert.issue.idNotReadableAsText",
        "legacy.convert.issue.dateMissing",
        "legacy.convert.issue.dateNotACalendarDay",
        "legacy.convert.issue.paymentDateNotACalendarDay",
        "legacy.convert.issue.dueDateNotACalendarDay",
        "legacy.convert.issue.totalAmountNotANumber",
        "legacy.convert.issue.taxAmountNotANumber",
        "legacy.convert.issue.taxRateNotANumber",
        "legacy.convert.issue.paidAmountNotANumber",
        "legacy.convert.issue.amountWithoutTaxNotANumber",
        "legacy.convert.issue.paymentStatusUnrecognized",
        "legacy.convert.issue.counterpartyWouldBeTruncated",
        "legacy.convert.issue.invoiceNoWouldBeTruncated",
        "legacy.convert.issue.counterpartyNotReadableAsText",
        "legacy.convert.issue.invoiceNoNotReadableAsText",
        "legacy.convert.issue.paymentDateNotReadableAsText",
        "legacy.convert.issue.dueDateNotReadableAsText",
        // F 方向映射（1 键）
        "legacy.convert.mapping.note",
        // G 类别选择（5 键）
        "legacy.convert.category.title",
        "legacy.convert.category.income",
        "legacy.convert.category.expense",
        "legacy.convert.category.placeholder",
        "legacy.convert.category.note",
        // H 后果披露：转换会改变什么（10 键）
        "legacy.convert.consequence.title",
        "legacy.convert.consequence.reportSource",
        "legacy.convert.consequence.currency",
        "legacy.convert.consequence.shipping",
        "legacy.convert.consequence.lineItems",
        "legacy.convert.consequence.createdAt",
        "legacy.convert.consequence.statuses",
        "legacy.convert.consequence.sourceRecord",
        "legacy.convert.consequence.legacyRowsKept",
        "legacy.convert.consequence.attachments",
        // I 年度前瞻（5 键）
        "legacy.convert.year.title",
        "legacy.convert.year.existing",
        "legacy.convert.year.noneYet",
        "legacy.convert.year.secondCurrency",
        "legacy.convert.year.upperBound",
        // J 转换前备份（3 键）
        "legacy.convert.backup.title",
        "legacy.convert.backup.note",
        "legacy.convert.backup.scope",
        // K 运行与完成（8 键）
        "legacy.convert.running.title",
        "legacy.convert.running.message",
        "legacy.convert.done.title",
        "legacy.convert.done.message",
        "legacy.convert.done.skipped",
        "legacy.convert.done.backup",
        "legacy.convert.done.legacyKept",
        "legacy.convert.done.reportNote",
        // L 失败：12 个 failure case 的用户可见文案 + 标题 + 重试说明（14 键）
        "legacy.convert.failed.title",
        "legacy.convert.failed.categoryRequiredIncome",
        "legacy.convert.failed.categoryRequiredExpense",
        "legacy.convert.failed.categoryNotFound",
        "legacy.convert.failed.categoryWrongType",
        "legacy.convert.failed.categoryWrongLocale",
        "legacy.convert.failed.ledgerChanged",
        "legacy.convert.failed.rowVanished",
        "legacy.convert.failed.rowNoLongerConvertible",
        "legacy.convert.failed.backupFailed",
        "legacy.convert.failed.backupNotValid",
        "legacy.convert.failed.busy",
        "legacy.convert.failed.internal",
        "legacy.convert.failed.retryNote",
    ]

    // MARK: - Reading the committed sources

    /// …/App/Tests/SoloLedgerUnitTests/<this>.swift → …/native/SoloLedger
    private static func packageRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        return dir
    }

    private static func sourceStringsURL(_ language: String) -> URL {
        packageRoot()
            .appendingPathComponent("Sources/SoloLedger/Resources/\(language).lproj/Localizable.strings")
    }

    /// The COMMITTED `.strings` of a locale, parsed as the old-style property list it is.
    private func sourceTable(_ language: String) throws -> [String: String] {
        let data = try Data(contentsOf: Self.sourceStringsURL(language))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: String],
                             "\(language): Localizable.strings is not a string dictionary")
    }

    private func value(_ language: String, _ key: String) -> String {
        Localizer(language: language).t(key)
    }

    private func placeholders(in text: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: #"\{[A-Za-z]+\}"#)
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        })
    }

    // MARK: - T1 — the namespace is exactly the adjudicated size

    /// Absolute counts, not just parity.
    ///
    /// `testFullLocaleKeyUniverseRatchet` compares the six locales against each other, so six
    /// files that are all one key short agree perfectly and pass. The adjudicated table said 97;
    /// this is the assertion that knows it.
    ///
    /// The three neighbouring namespaces are pinned in the same breath because landing a
    /// conversion key in one of them is the likeliest way to be right about the total and wrong
    /// about where it went — and `report.*` is held to a closed set of 165 by
    /// `ReportStateCopyTests`, which would then fail somewhere far from the cause.
    func testT1TheConversionNamespaceIsExactlyNinetySevenKeys() throws {
        for language in languages {
            let table = try sourceTable(language)
            XCTAssertEqual(table.keys.filter { $0.hasPrefix("legacy.convert.") }.count, 97,
                           "\(language): the adjudicated conversion namespace is 97 keys")
            XCTAssertEqual(table.keys.filter { $0.hasPrefix("legacy.") }.count, 102,
                           "\(language): 5 reachable legacy.* + 97 dormant legacy.convert.*")
            XCTAssertEqual(table.keys.filter { $0.hasPrefix("report.") }.count, 165,
                           "\(language): the report namespace must not have moved")
            XCTAssertEqual(table.keys.filter { $0.hasPrefix("settings.") }.count, 36,
                           "\(language): the settings namespace must not have moved")
            XCTAssertEqual(table.count, 755, "\(language): 496 + 41 + 1 + 2 + 94 + 11 + 5 + 105 (documents.* 104 + nav.documents 1)")
        }
        XCTAssertEqual(Set(Self.conversionCopyKeys).count, 97,
                       "the declared key list has a duplicate")
    }

    // MARK: - T2 — every declared key resolves, in every language

    /// Driven from the CODE-side list, which is the half `testFullLocaleKeyUniverseRatchet`
    /// cannot do: it compares the files to each other, so a key the adjudication called for and
    /// nobody wrote is absent from all six and agrees with itself.
    func testT2EveryConversionKeyResolvesInAllSixLocales() throws {
        for language in languages {
            let table = try sourceTable(language)
            for key in Self.conversionCopyKeys {
                let onDisk = try XCTUnwrap(table[key], "\(language) is missing \(key)")
                XCTAssertFalse(onDisk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(language)/\(key) is empty")
                let resolved = value(language, key)
                XCTAssertNotEqual(resolved, key, "\(language)/\(key) resolved to the raw key")
                XCTAssertEqual(resolved, onDisk,
                               "\(language)/\(key): the bundle and the source disagree")
            }
        }
    }

    // MARK: - T2b — the placeholder grammar, including the shapes parity cannot see

    /// Parity compares `{token}` SETS, so it is blind to the three ways a placeholder gets
    /// written wrong without ceasing to look like prose: `{ count }`, `{count1}` and the
    /// full-width `｛count｝` all fail to match `\{[A-Za-z]+\}`, which makes every parity check
    /// conclude the key simply has no placeholder and pass. A stray brace is the only evidence
    /// left, so that is what this looks for.
    func testT2bPlaceholdersAreTheApprovedTokensAndNothingElse() throws {
        for key in Self.conversionCopyKeys {
            var sets: [Set<String>] = []
            for language in languages {
                let text = try XCTUnwrap(sourceTable(language)[key])
                let tokens = placeholders(in: text)
                sets.append(tokens)
                for token in tokens {
                    XCTAssertTrue(Self.allowedPlaceholders.contains(token),
                                  "\(language)/\(key) uses an unapproved token \(token)")
                }
                var residue = text
                for token in tokens { residue = residue.replacingOccurrences(of: token, with: "") }
                XCTAssertFalse(residue.contains("{") || residue.contains("}"),
                               "\(language)/\(key) holds a brace that is not a valid token")
                XCTAssertFalse(text.contains("｛") || text.contains("｝"),
                               "\(language)/\(key) uses full-width braces, which no substitution matches")
            }
            XCTAssertEqual(Set(sets).count, 1,
                           "\(key): the six locales do not agree on the placeholder set — \(sets)")
        }
        XCTAssertEqual(placeholders(in: value("zh-Hans", "legacy.convert.consequence.statuses")),
                       ["{issued}", "{pending}", "{na}"])
        for language in languages {
            XCTAssertEqual(placeholders(in: value(language, "legacy.convert.consequence.statuses")),
                           ["{issued}", "{pending}", "{na}"],
                           "\(language): the status disclosure must interpolate exactly three labels")
        }
    }

    // MARK: - T3 — one sentence per row issue, both directions

    /// A one-way assertion only defends one direction, and both are reachable: a new
    /// `LegacyRowIssue` with no sentence leaves the wizard rendering a raw key, and a sentence
    /// for a case that no longer exists is dead copy six-locale parity waves straight through.
    func testT3EveryRowIssueHasExactlyOneSentenceAndViceVersa() throws {
        let prefix = "legacy.convert.issue."
        let expected = Set(LegacyRowIssue.allCases.map { prefix + $0.rawValue })
        XCTAssertEqual(expected.count, 17, "the seventeen graded issues")
        for language in languages {
            let onDisk = Set(try sourceTable(language).keys.filter { $0.hasPrefix(prefix) })
            XCTAssertEqual(onDisk, expected, """
                \(language): the issue copy and the enum disagree.
                in the file, matching no case (delete it): \(onDisk.subtracting(expected).sorted())
                a case with no sentence (add it): \(expected.subtracting(onDisk).sorted())
                """)
        }
    }

    // MARK: - T4 — the failure copy is not the failure's own words

    /// 2a-3 can only assert the negative half of the contract: the routing from a
    /// `LegacyConversionFailure` to a key is 2a-4's, but the copy that routing will reach exists
    /// now, and it can be proved not to be `description`.
    ///
    /// The fragment list is checked in BOTH directions. Each fragment must really occur in one
    /// of the twelve descriptions — otherwise a renamed case would quietly leave this test
    /// asserting the absence of text nobody produces any more.
    func testT4FailureCopyNeverLeaksTheDescriptionOrItsPayload() throws {
        let sale = LegacyRowIdentity(table: .sales, legacyID: "s-1")
        let purchase = LegacyRowIdentity(table: .purchases, legacyID: "p-1")
        let failures: [LegacyConversionFailure] = [
            .skippedIdentityNotConvertible(sale),
            .categoryRequired(.income),
            .categoryNotFound(id: "cat-1"),
            .categoryWrongType(id: "cat-1", expected: .income, actual: .expense),
            .categoryWrongLocale(id: "cat-1", expected: "CN", actual: "US"),
            .ledgerChanged,
            .rowVanished(purchase),
            .rowNoLongerConvertible(sale, [.dateMissing]),
            .writeSetMismatch("owed 2 got 1"),
            .backupFailed("no such directory"),
            .backupNotValid("missing sololedger.db"),
            .busy("database is locked (code 5)"),
        ]
        XCTAssertEqual(failures.count, 12, "every case of the enum is represented")
        let descriptions = failures.map(\.description)

        // Distinctive of the machine text, never of prose a translator would write.
        let fragments = [
            "Cannot skip", "convertible set", "The conversion includes", "Category not found",
            "category is required", "not to this ledger's",
            "The ledger changed since the plan was made", "is no longer convertible",
            "Conversion closing check failed", "The pre-conversion backup failed",
            "did not validate", "being written by another process",
            "sales:", "purchases:",
        ]
        for fragment in fragments {
            XCTAssertTrue(descriptions.contains { $0.contains(fragment) },
                          "\(fragment) no longer appears in any description — this list is stale")
        }

        let failureKeys = Self.conversionCopyKeys.filter { $0.hasPrefix("legacy.convert.failed.") }
        XCTAssertEqual(failureKeys.count, 14, "twelve cases, a title and the retry note")
        for language in languages {
            for key in failureKeys {
                let copy = value(language, key)
                for fragment in fragments {
                    XCTAssertFalse(copy.contains(fragment),
                                   "\(language)/\(key) carries the machine's own words: \(fragment)")
                }
                for description in descriptions {
                    XCTAssertFalse(copy.contains(description),
                                   "\(language)/\(key) is a LegacyConversionFailure description")
                }
                for issue in LegacyRowIssue.allCases {
                    XCTAssertFalse(copy.contains(issue.rawValue),
                                   "\(language)/\(key) exposes the raw issue name \(issue.rawValue)")
                }
            }
        }
    }

    // MARK: - T5 — zero banned-wording hits, scanned with an EMPTY sanction table

    /// Scanned with `sanctioned: []` on purpose. The tree's own scan passes the real table, so a
    /// hit that happened to sit on an already-sanctioned triple would be waved through; this
    /// stage's contract is stronger — the new copy trips nothing at all, which is what keeps
    /// `sanctionedUses` at forty without this PR touching the guard.
    func testT5NewCopyHasZeroBannedWordingHits() throws {
        let source = try String(contentsOf: Self.guardSourceURL(), encoding: .utf8)
        let filing = try Self.patterns(inArrayNamed: "filingWords", of: source)
        let statutory = try Self.patterns(inArrayNamed: "statutoryStatementNames", of: source)
        XCTAssertEqual(filing.count, 22, "the filing vocabulary must stay at twenty-two")
        XCTAssertEqual(statutory.count, 21, "the statutory names must stay at twenty-one")
        XCTAssertEqual(Self.sanctionCount(of: source), 40,
                       "no sanction may be added for this stage's copy")

        var hits: [String] = []
        for pattern in filing + statutory {
            let regex = try NSRegularExpression(pattern: pattern)
            for language in languages {
                let table = try sourceTable(language)
                for key in Self.conversionCopyKeys {
                    let text = try XCTUnwrap(table[key])
                    let range = NSRange(text.startIndex..., in: text)
                    if regex.firstMatch(in: text, range: range) != nil {
                        hits.append("\(language)/\(key): \(pattern)")
                    }
                }
            }
        }
        XCTAssertTrue(hits.isEmpty, """
            the conversion copy trips the wording guard, and this stage may not add a sanction:
            \(hits.sorted().joined(separator: "\n"))
            """)

        // Anti-vacuity: the same scan, over a value that really does carry a banned word.
        let poisoned = "旧版发票状态中的「已开 / 已收」会写为「已开票」。"
        let caught = try filing.contains { pattern in
            let regex = try NSRegularExpression(pattern: pattern)
            return regex.firstMatch(in: poisoned,
                                    range: NSRange(poisoned.startIndex..., in: poisoned)) != nil
        }
        XCTAssertTrue(caught, "the scan found nothing in a string that is a known violation")
    }

    private static func guardSourceURL() -> URL {
        packageRoot()
            .appendingPathComponent("Tests/SoloLedgerCoreTests/LocalizationWordingGuardTests.swift")
    }

    /// The patterns of one `[BannedWord]` table, read out of the guard's own source.
    ///
    /// Both literal shapes the guard uses are handled: raw (`#"(?i)\bFiling\b"#`, for everything
    /// that needs a backslash) and plain (`"申报"`, for the bare CJK words). A plain literal
    /// carrying an escape would mean the guard changed shape, and is rejected rather than
    /// silently mis-decoded.
    private static func patterns(inArrayNamed name: String, of source: String) throws -> [String] {
        let start = try XCTUnwrap(source.range(of: "static let \(name): [BannedWord] = ["),
                                  "\(name) is no longer a [BannedWord] array in the guard")
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    ]"), "\(name) has no closing bracket")
        let body = String(rest[..<end.lowerBound])
        // `##"…"##`, because the pattern itself contains `"#` — the raw-string delimiter the
        // guard uses for its own Latin patterns — and a single-hash literal would end there.
        let regex = try NSRegularExpression(
            pattern: ##"\.init\(pattern:\s*(#"[^"]*"#|"[^"]*")"##)
        let range = NSRange(body.startIndex..., in: body)
        return try regex.matches(in: body, range: range).map { match -> String in
            let captured = try XCTUnwrap(Range(match.range(at: 1), in: body))
            let literal = String(body[captured])
            if literal.hasPrefix("#\"") {
                return String(literal.dropFirst(2).dropLast(2))
            }
            let plain = String(literal.dropFirst().dropLast())
            XCTAssertFalse(plain.contains("\\"),
                           "a plain literal now carries an escape — the decoder would corrupt it")
            return plain
        }
    }

    private static func sanctionCount(of source: String) -> Int {
        guard let start = source.range(of: "static let sanctionedUses: [SanctionedUse] = ["),
              let end = source.range(of: "// MARK: - The scan", range: start.upperBound..<source.endIndex)
        else { return -1 }
        return source[start.upperBound..<end.lowerBound].components(separatedBy: ".init(locale:").count - 1
    }

    // MARK: - T6 — the copy is reachable, and every string of it is placed

    /// 2a-3 asserted the opposite: that no file in the SwiftUI target named any of the
    /// ninety-seven keys. That was the whole contract of shipping the copy dormant, and 2a-4 is
    /// the change it was waiting for.
    ///
    /// What replaces it is stronger than "at least one key is used now". The wizard draws
    /// EVERY key from ``LegacyConversionComposition/placement``, so the table is asserted to be
    /// exactly the adjudicated set in both directions: a key with no placement is copy nothing
    /// can reach, and a placement with no key is a render that would resolve to a raw string.
    /// The scan is kept as the anti-vacuity half — it is what would notice if the composition
    /// table were satisfied by a file the app does not actually build.
    func testT6TheConversionCopyIsReachableAndEveryKeyIsPlaced() throws {
        let placed = Set(LegacyConversionComposition.placement.keys)
        let adjudicated = Set(Self.conversionCopyKeys)
        XCTAssertEqual(placed, adjudicated, """
            the composition table and the adjudicated copy disagree.
            placed but not adjudicated (a render with no string): \(placed.subtracting(adjudicated).sorted())
            adjudicated but not placed (a string nothing can draw): \(adjudicated.subtracting(placed).sorted())
            """)
        XCTAssertEqual(placed.count, 97)

        let sources = try Self.appSources()
        XCTAssertGreaterThan(sources.count, 10, "the App target sources did not resolve")
        let found = Self.mentions(of: Self.conversionCopyKeys, in: sources)
        XCTAssertEqual(found, adjudicated, """
            the conversion copy is no longer fully reachable from the App target: \
            \(adjudicated.subtracting(found).sorted())
            """)
    }

    func testT6TheReachabilityScanDetectsARealUseAndIgnoresAComment() {
        let use = [("Views/Wizard.swift", "Text(model.t(\"legacy.convert.cta\"))")]
        XCTAssertFalse(Self.mentions(of: Self.conversionCopyKeys, in: use).isEmpty,
                       "the scanner cannot see a real use, so its silence means nothing")

        let comment = [("Views/Wizard.swift", "    // legacy.convert.cta is mounted in 2a-4")]
        XCTAssertTrue(Self.mentions(of: Self.conversionCopyKeys, in: comment).isEmpty)

        let longer = [("Views/Wizard.swift", "t(\"legacy.convert.ctaExtra\")")]
        XCTAssertTrue(Self.mentions(of: ["legacy.convert.cta"], in: longer).isEmpty,
                      "whole-literal matching only")

        for key in [Self.conversionCopyKeys.first!, Self.conversionCopyKeys.last!] {
            XCTAssertEqual(Self.mentions(of: Self.conversionCopyKeys,
                                         in: [("X.swift", "t(\"\(key)\")")]).count, 1,
                           "\(key) must be individually detectable")
        }
    }

    /// Every `.swift` under the app's own source tree, as (path, text).
    private static func appSources() throws -> [(path: String, text: String)] {
        let root = packageRoot().appendingPathComponent("Sources/SoloLedger")
        let files = FileManager.default.enumerator(at: root,
                                                   includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Which of `keys` appear as a whole quoted literal in non-comment source text.
    private static func mentions(of keys: [String],
                                 in sources: [(path: String, text: String)]) -> Set<String> {
        var found: Set<String> = []
        for source in sources {
            for line in source.text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*")
                else { continue }
                for key in keys where line.contains("\"\(key)\"") { found.insert(key) }
            }
        }
        return found
    }

    // MARK: - T7 — the notice copy and the entry point land together

    /// The rewrite this test used to forbid, and the property that replaces the prohibition.
    ///
    /// On every commit up to 2a-3, `legacy.notice.message` said this app does not convert
    /// legacy records yet — and it was TRUE, because nothing mounted a wizard. 2a-4 mounts one,
    /// which makes the old sentence a false statement sitting directly above a button that
    /// contradicts it. So the sentence changed, and the only question left is whether it can
    /// ever change WITHOUT the button, or the button appear without the sentence.
    ///
    /// XCTest cannot read git history, so "the same commit" is expressed as a BICONDITIONAL
    /// over one source tree, and a tree holding only half of the pair fails:
    ///
    ///  * forwards — the copy claims a conversion can be started, so the entry point must be
    ///    composed for a ledger with unconverted rows, and must NOT be composed for the
    ///    `legacy.other.*` branch. This half is BEHAVIOURAL: it calls the same pure function
    ///    the views call.
    ///  * backwards — the entry point exists, so the retired over-claim must be gone from all
    ///    six values. Ratcheted on the WHOLE clause rather than on keywords: 转换 / convert /
    ///    変換 / 변환 appear legitimately all over the new copy.
    ///
    /// A source scan would be the weaker instrument for the forwards half and is deliberately
    /// not used for it; `LegacyConversionWizardTests` keeps one as a second line of defence.
    func testT7TheNoticeCopyAndTheEntryPointLandTogether() throws {
        XCTAssertEqual(Self.reachableLegacyCopy.count, 5)
        for (key, byLocale) in Self.reachableLegacyCopy {
            XCTAssertEqual(byLocale.count, 6, "\(key): all six locales must be pinned")
            for language in languages {
                let expected = try XCTUnwrap(byLocale[language])
                let landed = try XCTUnwrap(sourceTable(language)[key])
                XCTAssertEqual(landed, expected, "\(language)/\(key) differs from the adjudicated wording")
            }
        }

        // — forwards: the copy promises a conversion, so the entry point must be there —
        let unconverted = LegacyLedgerSummary(salesTotal: 2, salesUnconverted: 2)
        let notice = LegacyConversionComposition.notice(unconverted)
        XCTAssertEqual(notice.messageKey, "legacy.notice.message")
        XCTAssertEqual(notice.entry, ["legacy.convert.cta", "legacy.convert.cta.hint"],
                       "the notice promises a conversion but offers no way to start one")
        let banner = LegacyConversionComposition.banner(unconverted, ledgerIsEmpty: false)
        XCTAssertEqual(banner.entry, ["legacy.convert.cta", "legacy.convert.cta.hint"])

        // — and the branch that must never offer one —
        let othersOnly = LegacyLedgerSummary(otherRecords: 7)
        let otherNotice = LegacyConversionComposition.notice(othersOnly)
        XCTAssertEqual(otherNotice.messageKey, "legacy.other.message")
        XCTAssertTrue(otherNotice.entry.isEmpty,
                      "legacy.other.* records are not convertible; an entry point there could "
                      + "only ever report that there is nothing to convert")
        XCTAssertTrue(LegacyConversionComposition.banner(othersOnly, ledgerIsEmpty: false).entry.isEmpty)

        // — backwards: the entry point exists, so the retired claim must be gone, per locale —
        for (language, retired) in Self.retiredNoticeClauses {
            let landed = try XCTUnwrap(sourceTable(language)["legacy.notice.message"])
            XCTAssertFalse(landed.contains(retired), """
                \(language): the notice still says the app does not convert legacy records, on a \
                build whose notice carries the button that does.
                """)
        }
        XCTAssertEqual(Self.retiredNoticeClauses.count, 6)
    }

    /// The clause each locale used to carry, kept so its return is a failure rather than a
    /// silent regression. Anti-vacuity for this table is `testT7TheRetiredClausesWereRealText`.
    private static let retiredNoticeClauses: [String: String] = [
        "zh-Hans": "尚未提供把旧记录转换为流水的功能",
        "zh-Hant": "尚未提供將舊紀錄轉換為流水的功能",
        "en": "does not convert legacy records yet",
        "ja": "変換する機能はまだ提供していない",
        "ko": "변환하는 기능은 아직 제공하지 않으므로",
        "fr": "ne convertit pas encore les enregistrements hérités",
    ]

    /// The ratchet above asserts an absence, and an absence is also what a table of typos
    /// produces. Each clause is therefore checked against the value it was really taken from —
    /// the one this PR's base shipped — so a mistyped entry fails here instead of passing
    /// silently forever.
    func testT7TheRetiredClausesWereRealText() {
        let base = [
            "zh-Hans": "它们完整保存在账本文件中，没有丢失。本 App 目前只显示「流水」，尚未提供把旧记录转换为流水的功能，因此这里看不到它们。",
            "zh-Hant": "它們完整保存在帳本檔案中，沒有遺失。本 App 目前只顯示「流水」，尚未提供將舊紀錄轉換為流水的功能，因此這裡看不到它們。",
            "en": "They are stored intact in the ledger file — nothing was lost. This app currently shows only transactions and does not convert legacy records yet, so they are not listed here.",
            "ja": "これらは台帳ファイルにそのまま保存されており、失われていません。本アプリは現在「取引」のみを表示し、旧記録を取引へ変換する機能はまだ提供していないため、ここには表示されません。",
            "ko": "해당 기록은 장부 파일에 그대로 저장되어 있으며 사라지지 않았습니다. 이 앱은 현재 ‘거래’만 표시하고 이전 기록을 거래로 변환하는 기능은 아직 제공하지 않으므로 여기에는 나타나지 않습니다.",
            "fr": "Ils sont conservés intacts dans le fichier de comptabilité — rien n'a été perdu. Cette app n'affiche pour l'instant que les écritures et ne convertit pas encore les enregistrements hérités, ils ne sont donc pas listés ici.",
        ]
        for (language, clause) in Self.retiredNoticeClauses {
            XCTAssertTrue(base[language]?.contains(clause) == true,
                          "\(language): the retired clause is not what the base actually said, so "
                          + "the ratchet is asserting the absence of text nobody ever wrote")
        }
        // And the fact that made the rewrite necessary: the preserved half is still there.
        for language in languages {
            let landed = value(language, "legacy.notice.message")
            XCTAssertFalse(landed.isEmpty)
        }
    }

    // MARK: - T8 — the other-records notice promises nothing

    /// `legacy.other.*` renders when `hasUnconverted` is FALSE — invoices, fixed assets and
    /// the rest. `LegacyConversionPlan` does not scan those tables and the runner cannot carry
    /// them, so a conversion entry point there would be a button that can only ever report
    /// "nothing to convert". Keeping the promise out of the copy is the half of that this stage
    /// can enforce.
    func testT8TheOtherRecordsCopyMakesNoConversionPromise() throws {
        let roots = ["转换", "轉換", "変換", "변환", "convert", "convertir"]
        let keys = ["legacy.other.title", "legacy.other.message"]
        for language in languages {
            let table = try sourceTable(language)
            XCTAssertEqual(table.keys.filter { $0.hasPrefix("legacy.other.") }.count, keys.count)
            for key in keys {
                let stored = try XCTUnwrap(table[key])
                let copy = stored.lowercased()
                for root in roots {
                    XCTAssertFalse(copy.contains(root.lowercased()),
                                   "\(language)/\(key) promises a conversion these records "
                                   + "cannot have — the plan does not scan their tables")
                }
            }
        }
        // Anti-vacuity: the same check over a value that does make the promise.
        XCTAssertTrue(roots.contains { "把它们转换为流水".contains($0) })
    }

    // MARK: - T9 — the grades and the blockers are told apart

    /// "Skip it and carry on" and "no choice rescues this" are different offers. Two grades
    /// rendering the same sentence would leave the user unable to tell which one they are
    /// looking at, in a screen whose only purpose is that distinction.
    func testT9GradesAndBlockerTitlesAreMutuallyDistinct() throws {
        let grades = LegacyRowGrade.allCases.map { "legacy.convert.grade.\($0.rawValue)" }
        XCTAssertEqual(grades.count, 3)
        let blockers = Self.conversionCopyKeys.filter {
            $0.hasPrefix("legacy.convert.blocked.") && $0.hasSuffix(".title")
        }
        XCTAssertEqual(blockers.count, 5, "one title per LegacyConversionBlocker case")
        for (label, keys) in [("grades", grades), ("blocker titles", blockers)] {
            for language in languages {
                let table = try sourceTable(language)
                let rendered = try keys.map { try XCTUnwrap(table[$0]) }
                XCTAssertEqual(Set(rendered).count, rendered.count,
                               "\(label) [\(language)]: two of them read the same")
            }
        }
    }

    // MARK: - T10 — no two labels of one screen region read alike

    /// The extension of P3b's collision check to this wizard. Bucketed by region AND slot, not
    /// by prefix: two keys that never appear together are allowed to agree, and a check that
    /// ignored that would fire on legitimate copy.
    func testT10NoTwoKeysInOneWizardRegionRenderTheSameLabel() throws {
        let grades = LegacyRowGrade.allCases.map { "legacy.convert.grade.\($0.rawValue)" }
        let regions: [String: [String]] = [
            "grade counts": grades,
            "grade notes": grades.map { $0 + ".note" },
            "blocker titles": Self.keys(prefixed: "legacy.convert.blocked.", suffixed: ".title"),
            "blocker bodies": Self.keys(prefixed: "legacy.convert.blocked.", suffixed: ".body"),
            "row columns": Self.keys(prefixed: "legacy.convert.row.col."),
            "source tables": ["legacy.convert.table.sales", "legacy.convert.table.purchases"],
            "category labels": ["legacy.convert.category.income",
                                "legacy.convert.category.expense",
                                "legacy.convert.category.placeholder"],
            "consequences": Self.keys(prefixed: "legacy.convert.consequence.")
                .filter { $0 != "legacy.convert.consequence.title" },
            "row issues": Self.keys(prefixed: "legacy.convert.issue."),
            "failure bodies": Self.keys(prefixed: "legacy.convert.failed.")
                .filter { $0 != "legacy.convert.failed.title" },
            "year lines": ["legacy.convert.year.existing", "legacy.convert.year.noneYet",
                           "legacy.convert.year.secondCurrency", "legacy.convert.year.upperBound"],
        ]
        for (region, keys) in regions {
            XCTAssertGreaterThan(keys.count, 1, "\(region) is not a collision region")
            for language in languages {
                var byText: [String: [String]] = [:]
                let table = try sourceTable(language)
                for key in keys {
                    let text = try XCTUnwrap(table[key])
                    byText[text, default: []].append(key)
                }
                for (text, sharing) in byText where sharing.count > 1 {
                    XCTFail("\(region) [\(language)]: \(sharing.sorted()) all read “\(text)”")
                }
            }
        }
    }

    private static func keys(prefixed prefix: String, suffixed suffix: String = "") -> [String] {
        conversionCopyKeys.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
    }

    // MARK: - T11 — substitution leaves nothing behind

    /// `Localizer.t(_:_:)` does plain token replacement and reports nothing when a token has no
    /// value: the brace stays on screen. Rendering every key with every approved token is the
    /// only check that sees a placeholder written in a shape no substitution can match.
    func testT11EveryPlaceholderSubstitutesAwayIncludingAtZeroAndOne() {
        for language in languages {
            let localizer = Localizer(language: language)
            for key in Self.conversionCopyKeys {
                let rendered = localizer.t(key, Self.everyToken)
                XCTAssertFalse(rendered.contains("{") || rendered.contains("}"),
                               "\(language)/\(key) still holds a brace after substitution: \(rendered)")
                XCTAssertFalse(rendered.isEmpty)
            }
            // Zero and one are both reachable counts, and both read as ordinary prose.
            let counted = Self.conversionCopyKeys.filter {
                placeholders(in: value(language, $0)).contains("{count}")
            }
            XCTAssertEqual(counted.count, 7, "\(language): seven keys carry a count")
            for key in counted {
                for count in ["0", "1"] {
                    var tokens = Self.everyToken
                    tokens["count"] = count
                    let rendered = localizer.t(key, tokens)
                    XCTAssertFalse(rendered.contains("{count}"),
                                   "\(language)/\(key) did not substitute a count of \(count)")
                    XCTAssertTrue(rendered.contains(count),
                                  "\(language)/\(key) dropped the count entirely")
                }
            }
        }
    }

    // MARK: - T12 — the adjudicated high-risk sentences, byte for byte

    /// Nine sentences were adjudicated word by word because each one is a claim that would be
    /// wrong in a specific, costly way if it drifted: what "convertible" guarantees, what a
    /// skipped row's fate is, that an unreadable amount is not an absence, that shipping cost
    /// moves the China profile's tax lines, that the currency forecast is an upper bound rather
    /// than a verdict, that the backup is a whole-ledger replacement rather than an undo, that a
    /// lock wrote nothing, how the statuses map, and what the source record keeps.
    ///
    /// Pinned as an exact table, per locale. A softened verb is exactly the kind of edit that
    /// reads fine and changes what the app promises.
    func testT12TheAdjudicatedHighRiskConversionCopyIsExact() throws {
        XCTAssertEqual(Self.adjudicatedHighRiskCopy.count, 9)
        for (key, byLocale) in Self.adjudicatedHighRiskCopy {
            XCTAssertTrue(Self.conversionCopyKeys.contains(key), "\(key) is not in the landed set")
            XCTAssertEqual(byLocale.count, 6, "\(key): all six locales must be pinned")
            for language in languages {
                let landed = try XCTUnwrap(sourceTable(language)[key])
                let adjudicated = try XCTUnwrap(byLocale[language])
                XCTAssertEqual(landed, adjudicated,
                               "\(language)/\(key) differs from the adjudicated wording")
            }
        }
    }

    // MARK: - The 2a-4 interpolation contract, registered here

    /// Registered, not exercised: nothing mounts this copy yet.
    ///
    /// The three tokens must be filled from `invoice.issued` / `invoice.pending` / `invoice.na`,
    /// never hard-coded. That is not a style preference — the zh labels for the first of those
    /// ARE a `filingWords` pattern, sanctioned by triple on that key alone, so writing them into
    /// any other `.strings` value re-opens the violation this shape was chosen to avoid.
    func testTheStatusDisclosureInterpolatesFromTheInvoiceStatusKeys() throws {
        let sourceKeys = ["invoice.issued", "invoice.pending", "invoice.na"]
        for language in languages {
            let table = try sourceTable(language)
            let labels = try sourceKeys.map { try XCTUnwrap(table[$0], "\(language) lost \($0)") }
            let rendered = Localizer(language: language).t(
                "legacy.convert.consequence.statuses",
                ["issued": labels[0], "pending": labels[1], "na": labels[2]])
            for label in labels {
                XCTAssertTrue(rendered.contains(label),
                              "\(language): the disclosure lost the \(label) label")
            }
            XCTAssertFalse(rendered.contains("{") || rendered.contains("}"),
                           "\(language): a token survived the contract's own substitution")
        }
        // The reason the contract exists: the zh label is a banned word everywhere but its own key.
        let issuedLabel = try XCTUnwrap(sourceTable("zh-Hans")["invoice.issued"])
        XCTAssertTrue(issuedLabel.contains("已开票"))
        XCTAssertFalse(value("zh-Hans", "legacy.convert.consequence.statuses").contains("已开票"))
    }
}

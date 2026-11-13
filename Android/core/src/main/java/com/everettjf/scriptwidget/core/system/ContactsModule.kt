package com.everettjf.scriptwidget.core.system

import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.ContactsPickerSessionContract
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.NativeModule
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** One contact the user handed to a widget. Only these fields are ever stored or returned. */
class SelectedContact(val id: String, val name: String, val organization: String, val phones: List<String>, val emails: List<String>) {
    fun toJson(): JSONObject = JSONObject().put("id", id).put("name", name).put("organization", organization).put("phones", JSONArray(phones)).put("emails", JSONArray(emails))
}

/** Limits and pure rules of `$contacts`. */
object ContactRules {
    /** Contacts per installation. */
    const val MAXIMUM_SELECTED = 20
    const val MAXIMUM_PHONES = 3
    const val MAXIMUM_EMAILS = 3
    const val MAXIMUM_NAME_CHARACTERS = 256
    const val MAXIMUM_PHONE_CHARACTERS = 128
    const val MAXIMUM_EMAIL_CHARACTERS = 256
    private val uuid = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

    fun validID(value: String): Boolean = uuid.matches(value)

    /** Text without control or format characters, trimmed and cut to [maximum] characters. */
    fun text(raw: String?, maximum: Int): String {
        val clean = raw.orEmpty().filterNot { Character.isISOControl(it) || Character.getType(it) == Character.FORMAT.toInt() }.trim()
        val end = clean.offsetByCodePoints(0, minOf(maximum, clean.codePointCount(0, clean.length)))
        return clean.substring(0, end).trim()
    }

    /**
     * The documented shape of one contact: name and organization at most 256 characters, at most
     * three distinct nonempty phone numbers (128 characters each) and three e-mail addresses (256
     * each). Everything else a contact holds (notes, photo, birthday, addresses) is dropped here.
     */
    fun bounded(id: String, name: String?, organization: String?, phones: List<String?>, emails: List<String?>): SelectedContact = SelectedContact(
        id, text(name, MAXIMUM_NAME_CHARACTERS), text(organization, MAXIMUM_NAME_CHARACTERS),
        phones.map { text(it, MAXIMUM_PHONE_CHARACTERS) }.filter { it.isNotEmpty() }.distinct().take(MAXIMUM_PHONES),
        emails.map { text(it, MAXIMUM_EMAIL_CHARACTERS) }.filter { it.isNotEmpty() }.distinct().take(MAXIMUM_EMAILS),
    )

    /** True when [contact] already has the bounded shape; a stored record that does not is rejected. */
    fun valid(contact: SelectedContact): Boolean {
        fun ok(value: String, maximum: Int) = value == text(value, maximum)
        return validID(contact.id) && ok(contact.name, MAXIMUM_NAME_CHARACTERS) && ok(contact.organization, MAXIMUM_NAME_CHARACTERS) &&
            contact.phones.size <= MAXIMUM_PHONES && contact.phones.all { it.isNotEmpty() && ok(it, MAXIMUM_PHONE_CHARACTERS) } &&
            contact.emails.size <= MAXIMUM_EMAILS && contact.emails.all { it.isNotEmpty() && ok(it, MAXIMUM_EMAIL_CHARACTERS) }
    }
}

/**
 * The contacts the user picked for each installation. A record holds the documented fields and a
 * digest of the system contact it came from (to replace instead of duplicate when it is picked
 * again); the system identifier itself is not kept. A malformed file is `unavailable`.
 */
class ContactStore(private val directory: File) {
    private class Stored(val contact: SelectedContact, val origin: String)

    private fun file(installation: String) = PrivateFile(File(directory, ownerFileName(installation, ".json")), 128 * 1024)

    /** The installation's contacts in the order they were picked. */
    fun list(installation: String): List<SelectedContact> {
        if (!CallContext.isOwner(installation)) return emptyList()
        val file = file(installation)
        return synchronized(file.lock) { load(file).map { it.contact } }
    }

    /**
     * Adds one picked contact, or replaces the record of the same system contact ([originKey] is
     * hashed, never stored). Returns false when the installation is unknown or already has 20 contacts.
     */
    fun put(installation: String, originKey: String, name: String?, organization: String?, phones: List<String?>, emails: List<String?>): Boolean {
        if (!CallContext.isOwner(installation)) return false
        val file = file(installation)
        val origin = Canonical.sha256("$installation:contact:$originKey")
        return synchronized(file.lock) {
            val all = runCatching { load(file) }.getOrNull() ?: return@synchronized false
            val prior = all.firstOrNull { it.origin == origin }
            if (prior == null && all.size >= ContactRules.MAXIMUM_SELECTED) return@synchronized false
            val next = Stored(ContactRules.bounded(prior?.contact?.id ?: UUID.randomUUID().toString(), name, organization, phones, emails), origin)
            save(file, if (prior == null) all + next else all.map { if (it === prior) next else it })
        }
    }

    fun remove(installation: String, id: String): Boolean {
        if (!CallContext.isOwner(installation)) return false
        val file = file(installation)
        return synchronized(file.lock) {
            val all = runCatching { load(file) }.getOrNull() ?: return@synchronized false
            val remaining = all.filterNot { it.contact.id == id }
            remaining.size != all.size && save(file, remaining)
        }
    }

    /** Deletes everything stored for [installation], including an unreadable file. */
    fun clear(installation: String) {
        if (CallContext.isOwner(installation)) file(installation).let { synchronized(it.lock) { it.delete() } }
    }

    private fun load(file: PrivateFile): List<Stored> {
        val unavailable = { SystemServiceError.UNAVAILABLE.reject() }
        val text = try { file.read() } catch (error: PrivateFile.Unreadable) { throw unavailable() } ?: return emptyList()
        return try {
            val root = JSONObject(text)
            if (root.keys().asSequence().toSet() != setOf("formatVersion", "contacts") || root.get("formatVersion") != 1) throw unavailable()
            val array = root.getJSONArray("contacts")
            if (array.length() > ContactRules.MAXIMUM_SELECTED) throw unavailable()
            fun strings(values: JSONArray) = List(values.length()) { values.get(it) as? String ?: throw unavailable() }
            val all = List(array.length()) { index ->
                val item = array.getJSONObject(index)
                if (item.keys().asSequence().toSet() != setOf("id", "name", "organization", "phones", "emails", "origin")) throw unavailable()
                val stored = Stored(SelectedContact(item.getString("id"), item.getString("name"), item.getString("organization"), strings(item.getJSONArray("phones")), strings(item.getJSONArray("emails"))), item.getString("origin"))
                if (!ContactRules.valid(stored.contact) || !Regex("^[0-9a-f]{64}$").matches(stored.origin)) throw unavailable()
                stored
            }
            if (all.map { it.contact.id }.toSet().size != all.size) throw unavailable()
            all
        } catch (error: org.json.JSONException) { throw unavailable() }
    }

    private fun save(file: PrivateFile, all: List<Stored>): Boolean =
        file.write(JSONObject().put("formatVersion", 1).put("contacts", JSONArray(all.map { it.contact.toJson().put("origin", it.origin) })).toString())
}

/**
 * `$contacts.selected()`: the contacts the user picked for this installation in the app, as
 * `[{id, name, organization, phones, emails}]`. The call passes the system gate (`contacts`
 * declared by an installed Runtime 1.6 package, not a future timeline entry or Live Activity, the
 * query budget). The app holds no contacts permission: it can only return what the system picker
 * handed over, so the per-installation selection is the native grant and an installation
 * without one gets an empty list.
 */
class ContactsModule(private val store: ContactStore) : NativeModule {
    override val apis: Set<String> = setOf("\$contacts")

    override fun handles(operation: String): Boolean = operation.startsWith("contacts.")

    override fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        val context = CallContext.from(request)
        when (operation) {
            "contacts.selected" -> runSystemCall(operation, done) { selected(context).toString() }
            else -> done(false, JSONObject.quote("Unsupported operation $operation"))
        }
    }

    fun selected(context: CallContext): JSONArray {
        SystemGate.check(context, PERMISSION, writing = false, grants = null)
        val rows = store.list(context.installation).take(ContactRules.MAXIMUM_SELECTED)
        SystemGate.validate(context, PERMISSION, writing = false, grants = null)
        return JSONArray(rows.map { it.toJson() })
    }

    /** Deletes the selection of a deleted installation. */
    fun retire(installation: String) {
        store.clear(installation)
        SystemLog.call("contacts.retire", "ok")
    }

    companion object {
        const val PERMISSION = "contacts"
    }
}

/**
 * Reads what the system contact picker handed over and stores the documented fields. The app
 * never holds `READ_CONTACTS`: every read below is authorized only by the picker's result.
 */
class ContactImporter(context: Context, private val store: ContactStore) {
    private val appContext = context.applicationContext

    /**
     * True on Android 17 and later, where the contacts picker returns only the requested data
     * fields. Launching it can still fail on a device without the picker; callers fall back to
     * the classic single-contact picker then.
     */
    fun sessionPickerAvailable(): Boolean = Build.VERSION.SDK_INT >= 37

    /** The Android 17 picker, limited to [limit] contacts and to phone numbers, e-mail addresses and the organization. */
    fun sessionPickerIntent(limit: Int): Intent = Intent(ContactsPickerSessionContract.ACTION_PICK_CONTACTS)
        .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        .putExtra(ContactsPickerSessionContract.EXTRA_PICK_CONTACTS_SELECTION_LIMIT, limit.coerceIn(1, ContactRules.MAXIMUM_SELECTED))
        .putStringArrayListExtra(ContactsPickerSessionContract.EXTRA_PICK_CONTACTS_REQUESTED_DATA_FIELDS, arrayListOf(
            ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE, ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE, ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE))
        .putExtra(ContactsPickerSessionContract.EXTRA_PICK_CONTACTS_MATCH_ALL_DATA_FIELDS, false)

    /** Stores the contacts of an Android 17 picker session. Returns how many were stored. */
    fun importSession(installation: String, session: Uri): Int {
        val stored = runCatching {
            val people = LinkedHashMap<String, Picked>()
            appContext.contentResolver.query(session, null, null, null, null)?.use { cursor -> collect(cursor, people) }
            people.entries.count { (key, person) -> store.put(installation, key, person.name, person.organization, person.phones, person.emails) }
        }.getOrDefault(0)
        SystemLog.call("contacts.import", "ok count=$stored")
        return stored
    }

    /**
     * Stores one contact returned by the classic single-contact picker. The name is always
     * readable through the picker's grant; phone numbers, e-mail addresses and the organization are
     * read when the contacts provider extends the grant to the contact's data rows, and stay empty otherwise.
     */
    fun importPicked(installation: String, contact: Uri): Boolean {
        val stored = runCatching {
            val resolver = appContext.contentResolver
            val person = Picked()
            var key = contact.toString()
            resolver.query(contact, arrayOf(ContactsContract.Contacts.LOOKUP_KEY, ContactsContract.Contacts.DISPLAY_NAME_PRIMARY), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) { key = cursor.getString(0) ?: key; person.name = cursor.getString(1) }
            } ?: return@runCatching false
            runCatching {
                resolver.query(Uri.withAppendedPath(contact, ContactsContract.Contacts.Entity.CONTENT_DIRECTORY),
                    arrayOf(ContactsContract.Contacts.Entity.MIMETYPE, ContactsContract.Contacts.Entity.DATA1), null, null, null)?.use { cursor ->
                    while (cursor.moveToNext() && cursor.position < MAXIMUM_ROWS) person.add(cursor.getString(0), cursor.getString(1))
                }
            }
            store.put(installation, key, person.name, person.organization, person.phones, person.emails)
        }.getOrDefault(false)
        SystemLog.call("contacts.import", if (stored) "ok count=1" else "not_stored")
        return stored
    }

    private class Picked {
        var name: String? = null
        var organization: String? = null
        val phones = ArrayList<String?>()
        val emails = ArrayList<String?>()

        fun add(mimeType: String?, value: String?) {
            when (mimeType) {
                ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE -> phones += value
                ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE -> emails += value
                ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE -> if (organization.isNullOrBlank()) organization = value
            }
        }
    }

    /** Groups the data rows of a picker session by contact. Columns are looked up by name; unknown layouts yield nothing. */
    private fun collect(cursor: Cursor, people: MutableMap<String, Picked>) {
        fun column(vararg names: String): Int = names.map { cursor.getColumnIndex(it) }.firstOrNull { it >= 0 } ?: -1
        val contact = column(ContactsContract.Data.CONTACT_ID, ContactsContract.Data.LOOKUP_KEY, ContactsContract.Data.RAW_CONTACT_ID)
        val name = column(ContactsContract.Data.DISPLAY_NAME_PRIMARY)
        val mimeType = column(ContactsContract.Data.MIMETYPE)
        val data = column(ContactsContract.Data.DATA1)
        if (contact < 0) return
        while (cursor.moveToNext() && cursor.position < MAXIMUM_ROWS) {
            val key = cursor.getString(contact) ?: continue
            if (key !in people && people.size >= ContactRules.MAXIMUM_SELECTED) continue
            val person = people.getOrPut(key) { Picked() }
            if (name >= 0 && person.name.isNullOrBlank()) person.name = cursor.getString(name)
            if (mimeType >= 0 && data >= 0) person.add(cursor.getString(mimeType), cursor.getString(data))
        }
    }

    private companion object {
        /** Upper bound on rows read from one picker result. */
        const val MAXIMUM_ROWS = 2000
    }
}

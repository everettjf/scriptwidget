package com.everettjf.scriptwidget

import android.content.Context
import com.everettjf.scriptwidget.core.gallery.FetchGalleryTransport
import com.everettjf.scriptwidget.core.gallery.GalleryIndexCache
import com.everettjf.scriptwidget.core.gallery.GalleryInstallationRegistry
import com.everettjf.scriptwidget.core.gallery.GalleryInstaller
import com.everettjf.scriptwidget.core.gallery.GalleryRepository
import com.everettjf.scriptwidget.core.skills.SkillStore
import java.io.File

/**
 * Process-wide Gallery 1.0 and Skills 1.0 services. Everything here blocks on network or disk:
 * call it from `Dispatchers.IO`, never from the main thread.
 *
 * Skills live in `files/Skills`, the validated index cache and download scratch space in the
 * cache directory, and the installation records in `files/gallery-installations.json`. Widgets
 * are installed into the same hardened [com.everettjf.scriptwidget.core.pkg.PackageStore] as
 * every other package.
 */
class GalleryServices private constructor(context: Context) {
    private val transport = FetchGalleryTransport(AppServices.runtime.fetch)

    val skills = SkillStore(File(context.filesDir, "Skills"))
    val repository = GalleryRepository(transport, GalleryIndexCache(File(context.cacheDir, "ScriptWidgetGallery")))
    val installer = GalleryInstaller(
        transport = transport,
        registry = GalleryInstallationRegistry(File(context.filesDir, "gallery-installations.json")),
        packages = AppServices.library.store,
        skills = skills,
        temporaryRoot = File(context.cacheDir, "gallery-downloads"),
        // The API version this build implements; a widget that needs a newer one is refused.
        runtimeApiVersion = AppServices.runtime.scripts.contract.getString("apiVersion"),
        carriedFiles = listOf(Library.INSTALLATION_FILE),
    )

    companion object {
        @Volatile private var instance: GalleryServices? = null

        fun get(context: Context): GalleryServices =
            instance ?: synchronized(this) { instance ?: GalleryServices(context.applicationContext).also { instance = it } }
    }
}

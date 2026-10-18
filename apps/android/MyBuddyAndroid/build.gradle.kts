// Versions are pinned in gradle/libs.versions.toml (verified against the registries; see docs/research/DEPENDENCIES.md).
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}

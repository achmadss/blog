---
title: "Making Android SharedPreferences Actually Nice to Use"
date: 2025-05-07
description: "A look at a centralized, reactive, and extensible pattern."
categories: [software-development]
tags: [android, shared-preferences]
lang: en
canonical_url: https://blog.achmad.dev/posts/shared-preferences/
---

In my day to day work in Android development, I (still) use `SharedPreferences` for storing simple key-value data locally on a device. Recently, I've been looking through the [Mihon](https://github.com/mihonapp/mihon) codebase, and their way of handling `SharedPreferences` in my opinion makes working with preferences much more convinient.

### The Classic Way

Using `SharedPreferences` usually goes something like this:

```kotlin
val prefs = PreferenceManager.getDefaultSharedPreferences(context)
val isDarkMode = prefs.getBoolean("dark_mode_key", false)

prefs.edit {
    putBoolean("dark_mode_key", true)
    // apply() or commit()
}
```

It works, sure. But when your app grows and you have a lot of preferences, it can get messy real fast. it can also get a bit manual when you want to react to changes in your UI.

### Mihon's Approach

Imagine you have a dedicated class for your UI-related preferences called `UiPreferences` for example. This class will contain any UI settings that you have.

```kotlin
class UiPreferences(
    private val preferenceStore: PreferenceStore, // Injected
) {
    fun themeDarkAmoled() = preferenceStore.getBoolean("pref_theme_dark_amoled_key", false)
}
```

Now, in your ViewModel, you can access the preference and expose them as a `StateFlow`:

```kotlin
@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val uiPreferences: UiPreferences // Injected
) : ViewModel() {

    val isAmoledDark: StateFlow<Boolean> = uiPreferences.themeDarkAmoled().stateIn(viewModelScope)
    val themeMode: StateFlow<ThemeMode> = uiPreferences.themeMode().stateIn(viewModelScope)

    fun setAmoledDarkEnabled(enabled: Boolean) = uiPreferences.themeDarkAmoled().set(enabled)
    fun setThemeMode(themeMode: ThemeMode) = uiPreferences.themeMode().set(themeMode)
}
```

And in your UI (here I use Jetpack Compose), collecting these states is straightforward:

```kotlin
@Composable
fun SettingsScreen(
  viewModel: SettingsViewModel = hiltViewModel()
) {
    val isAmoledDark by viewModel.isAmoledDark.collectAsState()
    val themeMode by viewModel.themeMode.collectAsState()

    Column {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clickable { viewModel.setAmoledDarkEnabled(!isAmoledDark) }
                .padding(16.dp)
        ) {
            Text("AMOLED Dark Mode", modifier = Modifier.weight(1f))
            Switch(
                checked = isAmoledDark,
                onCheckedChange = { viewModel.setAmoledDarkEnabled(it) }
            )
        }

        Text("App Theme Mode: ${themeMode.name}")
        Row {
            Button(onClick = { viewModel.setThemeMode(ThemeMode.LIGHT) }) { Text("Light") }
            Button(onClick = { viewModel.setThemeMode(ThemeMode.DARK) }) { Text("Dark") }
            Button(onClick = { viewModel.setThemeMode(ThemeMode.SYSTEM) }) { Text("System") }
        }
    }
}
```

Clean and (most importantly) easy right? Because the `isAmoledDark` is a `StateFlow` that is derived from a `Flow` that listens to preference changes, the UI will recompose with the new state.

### How It Works Under the Hood

Let's break down the key components:

#### 1. The Preference Interface

This is the interface for any preference:

```kotlin
interface Preference<T> {
    fun key(): String
    fun get(): T
    fun set(value: T)
    fun isSet(): Boolean
    fun delete()
    fun defaultValue(): T
    fun changes(): Flow<T>
    fun stateIn(scope: CoroutineScope): StateFlow<T>
}
```

It defines standard operations (`get`, `set`, `key`, etc.) and also includes:
*   `changes(): Flow<T>`: a `Flow` that emits the preference's value whenever it changes.
*   `stateIn(scope: CoroutineScope): StateFlow<T>`: a function to derive a state from the preference's value.

#### 2. AndroidPreference

`AndroidPreference` is the Android-specific implementation of `Preference` using `SharedPreferences`:

```kotlin
sealed class AndroidPreference<T>(
    private val preferences: SharedPreferences,
    private val keyFlow: Flow<String?>,
    private val key: String,
    private val defaultValue: T,
) : Preference<T> {

    abstract fun read(preferences: SharedPreferences, key: String, defaultValue: T): T
    abstract fun write(key: String, value: T): Editor.() -> Unit

    // ... other method overrides like get(), set() ...

    override fun changes(): Flow<T> {
        return keyFlow
            .filter { it == key || it == null }
            // Emit an initial dummy value to trigger `map { get() }` and immediately emit the current value
            .onStart { emit("ignition") }
            .map { get() }
            .conflate()
    }

    // ... subclasses like StringPrimitive, IntPrimitive, Object ...
    // e.g., AndroidPreference.StringPrimitive, AndroidPreference.BooleanPrimitive
}
```
in summary:
*   It holds the `SharedPreferences` instance and its specific `key`.
*   `keyFlow: Flow<String?>`: a *shared* Flow (we'll see where it comes from next) that emits the string key of *any* preference that changes.
*   `changes()`: Filters the `keyFlow` for its own key, then fetches and emits its current value.
*   It has subclasses for primitives (`StringPrimitive`, `IntPrimitive`, etc.) and a generic `Object<T>` for custom types (using provided serializer/deserializer functions).

#### 3. PreferenceStore Interface & AndroidPreferenceStore Implementation

`PreferenceStore` is the factory for creating `Preference<T>` objects:

```kotlin
interface PreferenceStore {
    fun getString(key: String, defaultValue: String = ""): Preference<String>
    fun getBoolean(key: String, defaultValue: Boolean = false): Preference<Boolean>
    // ... methods for getInt, getLong, getFloat, getStringSet ...
    fun <T> getObject(
        key: String,
        defaultValue: T,
        serializer: (T) -> String,
        deserializer: (String) -> T,
    ): Preference<T>
    // ... and getEnum extension based on getObject
}
```

and this is the Android-specific implementation of `PreferenceStore`:

```kotlin
class AndroidPreferenceStore(
    context: Context,
    private val sharedPreferences: SharedPreferences = PreferenceManager.getDefaultSharedPreferences(context),
) : PreferenceStore {

    private val keyFlow = sharedPreferences.keyFlow

    override fun getString(key: String, defaultValue: String): Preference<String> {
        return AndroidPreference.StringPrimitive(sharedPreferences, keyFlow, key, defaultValue)
    }
    // ... other factory methods (getBoolean, getInt, etc.) follow the same pattern ...
}
```

in `AndroidPreferenceStore`, there's a variable called `keyFlow` and it is the core implementation for the reactivity:

```kotlin
private val SharedPreferences.keyFlow
    get() = callbackFlow {
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key: String? ->
            trySend(key)
        }
        registerOnSharedPreferenceChangeListener(listener)
        awaitClose {
            unregisterOnSharedPreferenceChangeListener(listener)
        }
    }
```
in summary:
*   `PreferenceStore` defines how to get different types of `Preference<T>` objects.
*   `AndroidPreferenceStore` implements `PreferenceStore` using `SharedPreferences`.
*   The `keyFlow` is a `callbackFlow` to create a single `OnSharedPreferenceChangeListener` for the entire `SharedPreferences` instance. This `keyFlow` emits the string key of *any* preference that changes.
*   This *single* `keyFlow` is then passed to *every* `AndroidPreference` instance created by this store.

#### 4. Feature-Specific Preference Holders

Looking at the example class `UiPreferences`, it's simply a class that groups and holds related preferences:

```kotlin
class UiPreferences(
    private val preferenceStore: PreferenceStore,
) {
    fun themeDarkAmoled() = preferenceStore.getBoolean("pref_theme_dark_amoled_key", false)
    // ...
}
```
This organizes your preferences and makes them easy to discover and use.

### The Reactive Chain Summarized

1.  An `AndroidPreferenceStore` is created. It sets up its `keyFlow` which listens for any `SharedPreferences` change via a single listener.
2.  You request a specific preference (e.g., `uiPreferences.themeDarkAmoled()`). This creates an `AndroidPreference.BooleanPrimitive` instance, passing it the shared `keyFlow`.
3.  When you collect `changes()` or `stateIn()` on this preference instance in your ViewModel/UI:
    *   It immediately emits its current value (due to `onStart`).
    *   It starts listening to the shared `keyFlow`.
4.  If any `SharedPreferences` value changes:
    *   The `keyFlow` emits the `key` of the changed preference.
    *   `AndroidPreference` instance will filter the keys. If the emitted `key` matches its own, it re-fetches its value and emits the update.
5.  any UI that is collecting the flow will receive the updated value.

### Benefits of This Architecture

1.  **Ease of Use:** Getting, setting, and observing preferences becomes incredibly straightforward.
2.  **Centralized Management:** `AndroidPreferenceStore` is the single source for preference objects.
3.  **Feature-Specific Organization:** Keeps your preference definitions clean and tied to specific features.
4.  **Reactivity:** `Flow<T>` and `StateFlow<T>` make UI updates easy.
5.  **Type Safety:** Reduces `ClassCastException` risks.
6.  **Extensibility:** Easily add new preference types or even swap out the backing store in the future.

This approach to SharedPreferences is remarkably easy to use and highly extensible. If you're making a new project, definitely give this approach a try.

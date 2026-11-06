# flutter_local_notifications (Gson uses reflection/generics)
-keep class com.dexterous.** { *; }
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.** { *; }
# nearby_connections / Google Play Services
-keep class com.pkmnapps.nearby_connections.** { *; }
-keep class com.google.android.gms.nearby.** { *; }
-dontwarn com.google.android.play.core.**

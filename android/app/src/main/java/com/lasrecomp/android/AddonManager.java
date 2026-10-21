package com.lasrecomp.android;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/**
 * Manages game profiles and dynamic .recomp addon packages.
 */
public class AddonManager {
    private static final String TAG = "AddonManager";
    private static AddonManager sInstance;

    private final Map<String, GameProfile> mProfiles = new LinkedHashMap<>();
    private final File mBaseDir;

    public static synchronized AddonManager getInstance(File baseDir) {
        if (sInstance == null || !sInstance.mBaseDir.equals(baseDir)) {
            sInstance = new AddonManager(baseDir);
        }
        return sInstance;
    }

    private AddonManager(File baseDir) {
        this.mBaseDir = baseDir;
        registerBuiltins();
        scanAddons();
    }

    /** Register built-in supported games */
    private void registerBuiltins() {
        // Core 1: The Legend of Zelda: Link's Awakening (v1.0.0)
        GameProfile zelda = new GameProfile(
                0x01006BB00C6F0000L,
                "The Legend of Zelda: Link's Awakening",
                "1.0.0",
                Arrays.asList("ae16f71e002af8cb"),
                Arrays.asList("region_common"),
                200,
                true
        );
        mProfiles.put(zelda.getTitleIdHex(), zelda);
    }

    /** Scan addons/ directory for installed manifests and .recomp archives */
    public synchronized void scanAddons() {
        File addonsDir = new File(mBaseDir, "addons");
        if (!addonsDir.isDirectory()) {
            addonsDir.mkdirs();
            return;
        }

        // 1. Process any pending .recomp zip packages
        File[] files = addonsDir.listFiles();
        if (files != null) {
            for (File f : files) {
                if (f.isFile() && f.getName().toLowerCase(Locale.ROOT).endsWith(".recomp")) {
                    installRecompArchive(f);
                }
            }
        }

        // 2. Scan extracted addon directories containing manifest.json
        File[] dirs = addonsDir.listFiles();
        if (dirs != null) {
            for (File d : dirs) {
                if (d.isDirectory()) {
                    File manifest = new File(d, "manifest.json");
                    if (manifest.isFile()) {
                        GameProfile profile = parseManifest(manifest, d.getAbsolutePath());
                        if (profile != null) {
                            mProfiles.put(profile.getTitleIdHex(), profile);
                        }
                    }
                }
            }
        }
    }

    /** Parses a manifest.json file into a GameProfile */
    public static GameProfile parseManifest(File manifestFile, String addonDir) {
        try (InputStream in = new FileInputStream(manifestFile);
             BufferedReader reader = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8))) {
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) sb.append(line).append('\n');

            JSONObject json = new JSONObject(sb.toString());
            String gameIdHex = json.getString("game_id").trim().toLowerCase(Locale.ROOT);
            long titleId = Long.parseUnsignedLong(gameIdHex, 16);
            String name = json.optString("name", "Unknown Recomp Game");
            String version = json.optString("version", "1.0.0");
            String author = json.optString("author", "Community");

            List<String> buildIds = new ArrayList<>();
            JSONArray bArr = json.optJSONArray("build_ids");
            if (bArr != null) {
                for (int i = 0; i < bArr.length(); i++) buildIds.add(bArr.getString(i).toLowerCase(Locale.ROOT));
            }

            List<String> critFiles = new ArrayList<>();
            int minCount = 1;
            JSONObject romfsValidator = json.optJSONObject("romfs_validator");
            if (romfsValidator != null) {
                JSONArray cArr = romfsValidator.optJSONArray("critical_files");
                if (cArr != null) {
                    for (int i = 0; i < cArr.length(); i++) critFiles.add(cArr.getString(i));
                }
                minCount = romfsValidator.optInt("min_file_count", 1);
            }

            GameProfile profile = new GameProfile(titleId, name, version, buildIds, critFiles, minCount, false);
            profile.setAddonDir(addonDir);
            profile.setAuthor(author);
            return profile;
        } catch (Exception e) {
            android.util.Log.e(TAG, "Failed to parse manifest: " + manifestFile, e);
            return null;
        }
    }

    /** Installs a .recomp zip package into addons/<title_id>/ */
    public boolean installRecompArchive(File recompZip) {
        try (ZipInputStream zis = new ZipInputStream(new FileInputStream(recompZip))) {
            // Find manifest.json in the zip first to determine titleId
            byte[] manifestBytes = null;
            ZipEntry ze;
            while ((ze = zis.getNextEntry()) != null) {
                if (ze.getName().equals("manifest.json") || ze.getName().endsWith("/manifest.json")) {
                    java.io.ByteArrayOutputStream bo = new java.io.ByteArrayOutputStream();
                    byte[] buf = new byte[4096];
                    for (int n; (n = zis.read(buf)) > 0; ) bo.write(buf, 0, n);
                    manifestBytes = bo.toByteArray();
                    break;
                }
            }

            if (manifestBytes == null) {
                android.util.Log.e(TAG, "No manifest.json found in .recomp archive: " + recompZip.getName());
                return false;
            }

            JSONObject json = new JSONObject(new String(manifestBytes, StandardCharsets.UTF_8));
            String gameIdHex = json.getString("game_id").trim().toLowerCase(Locale.ROOT);
            File destDir = new File(mBaseDir, "addons/" + gameIdHex);
            if (!destDir.isDirectory() && !destDir.mkdirs()) return false;

            // Extract all files into destDir
            try (ZipInputStream extractZis = new ZipInputStream(new FileInputStream(recompZip))) {
                byte[] buf = new byte[8192];
                while ((ze = extractZis.getNextEntry()) != null) {
                    String name = ze.getName();
                    if (name.contains("..")) continue; // security check
                    File out = new File(destDir, name);
                    if (ze.isDirectory()) {
                        out.mkdirs();
                    } else {
                        File p = out.getParentFile();
                        if (p != null && !p.isDirectory()) p.mkdirs();
                        try (FileOutputStream fos = new FileOutputStream(out)) {
                            for (int n; (n = extractZis.read(buf)) > 0; ) fos.write(buf, 0, n);
                        }
                    }
                }
            }

            // Remove .recomp archive once extracted
            recompZip.delete();
            scanAddons();
            return true;
        } catch (Exception e) {
            android.util.Log.e(TAG, "Error installing recomp archive: " + recompZip, e);
            return false;
        }
    }

    public synchronized GameProfile getProfileByTitleId(long titleId) {
        String hex = String.format(Locale.ROOT, "%016x", titleId).toLowerCase(Locale.ROOT);
        return mProfiles.get(hex);
    }

    public synchronized GameProfile getProfileByTitleIdHex(String hex) {
        if (hex == null) return null;
        return mProfiles.get(hex.toLowerCase(Locale.ROOT));
    }

    public synchronized GameProfile findProfileForBuildId(String buildId) {
        if (buildId == null || buildId.isEmpty()) return null;
        for (GameProfile p : mProfiles.values()) {
            if (p.matchesBuildId(buildId)) return p;
        }
        return null;
    }

    public synchronized List<GameProfile> getAllProfiles() {
        return new ArrayList<>(mProfiles.values());
    }
}

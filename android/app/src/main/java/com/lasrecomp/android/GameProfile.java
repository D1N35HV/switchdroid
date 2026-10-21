package com.lasrecomp.android;

import java.io.File;
import java.io.Serializable;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/**
 * Definition of a Switch Recompilation Game Profile.
 * Represents either a built-in supported game (like Link's Awakening)
 * or a dynamically imported .recomp addon.
 */
public class GameProfile implements Serializable {
    private static final long serialVersionUID = 1L;

    private final long titleId;
    private final String titleIdHex;
    private final String titleName;
    private final String version;
    private final List<String> buildIds;
    private final List<String> criticalRomfsFiles;
    private final int minRomfsFiles;
    private final boolean isBuiltin;
    private String addonDir;
    private String author;

    public GameProfile(long titleId, String titleName, String version, List<String> buildIds,
                       List<String> criticalRomfsFiles, int minRomfsFiles, boolean isBuiltin) {
        this.titleId = titleId;
        this.titleIdHex = String.format(Locale.ROOT, "%016x", titleId).toLowerCase(Locale.ROOT);
        this.titleName = titleName;
        this.version = version;
        this.buildIds = new ArrayList<>(buildIds);
        this.criticalRomfsFiles = criticalRomfsFiles != null ? new ArrayList<>(criticalRomfsFiles) : new ArrayList<>();
        this.minRomfsFiles = minRomfsFiles;
        this.isBuiltin = isBuiltin;
        this.author = "SwitchRecomp Team";
    }

    public long getTitleId() { return titleId; }
    public String getTitleIdHex() { return titleIdHex; }
    public String getTitleName() { return titleName; }
    public String getVersion() { return version; }
    public List<String> getBuildIds() { return Collections.unmodifiableList(buildIds); }
    public List<String> getCriticalRomfsFiles() { return Collections.unmodifiableList(criticalRomfsFiles); }
    public int getMinRomfsFiles() { return minRomfsFiles; }
    public boolean isBuiltin() { return isBuiltin; }
    public String getAddonDir() { return addonDir; }
    public void setAddonDir(String dir) { this.addonDir = dir; }
    public String getAuthor() { return author; }
    public void setAuthor(String author) { this.author = author; }

    public boolean matchesBuildId(String id) {
        if (id == null || id.isEmpty()) return false;
        for (String b : buildIds) {
            if (b.equalsIgnoreCase(id)) return true;
        }
        return false;
    }

    /** Path to game's isolated directory: games/<title_id>/ */
    public File getGameDir(File baseFilesDir) {
        return new File(baseFilesDir, "games/" + titleIdHex);
    }

    /** Path to game's extracted RomFS & ExeFS: games/<title_id>/extracted/ */
    public File getExtractedDir(File baseFilesDir) {
        return new File(getGameDir(baseFilesDir), "extracted");
    }

    /** Path to game's compiled native library */
    public File getLibGameFile(File baseFilesDir) {
        return new File(getGameDir(baseFilesDir), "libgame.so");
    }

    /** Path to game's save folder */
    public File getSaveDir(File baseFilesDir) {
        return new File(getGameDir(baseFilesDir), "save");
    }

    /** Check if the game files have been extracted and meet integrity checks */
    public boolean isExtracted(File baseFilesDir) {
        File ext = getExtractedDir(baseFilesDir);
        File main = new File(ext, "exefs/main");
        if (!main.isFile()) return false;
        for (String crit : criticalRomfsFiles) {
            File f = new File(ext, "romfs/" + crit);
            if (!f.exists()) return false;
        }
        return true;
    }

    /** Check if native ARM64 library has been compiled for this game */
    public boolean isCompiled(File baseFilesDir) {
        return getLibGameFile(baseFilesDir).isFile();
    }
}

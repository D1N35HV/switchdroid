with open('runtime/ui/launcher.mm', 'rb') as f:
    content = f.read().decode('utf-8')

content_lf = content.replace('\r\n', '\n')

old_code = """            // Show compilation/extraction busy overlay whenever busy
            static bool test_busy = getenv("LARECOMP_LAUNCHER_SHOT") && (strstr(getenv("LARECOMP_LAUNCHER_SHOT"), ":extracting") ||
                                                                     strstr(getenv("LARECOMP_LAUNCHER_SHOT"), ":preparing") ||
                                                                     strstr(getenv("LARECOMP_LAUNCHER_SHOT"), ":skipask"));
            if (busy || test_busy) draw_busy_overlay(ds, job, test_busy);"""

new_code = """            // Show compilation/extraction busy overlay whenever busy
            static bool test_busy = getenv("LARECOMP_LAUNCHER_SHOT") && (strstr(getenv("LARECOMP_LAUNCHER_SHOT"), ":extracting") ||
                                                                     strstr(getenv("LARECOMP_LAUNCHER_SHOT"), ":preparing") ||
                                                                     strstr(getenv("LARECOMP_LAUNCHER_SHOT"), ":skipask"));
            std::string curr_job;
            pthread_mutex_lock(&g_lock);
            curr_job = g_job;
            pthread_mutex_unlock(&g_lock);
            if (busy || test_busy) draw_busy_overlay(ds, curr_job, test_busy);"""

assert old_code in content_lf, "old_code not found"
content_lf = content_lf.replace(old_code, new_code)

final_content = content_lf.replace('\n', '\r\n')
with open('runtime/ui/launcher.mm', 'wb') as f:
    f.write(final_content.encode('utf-8'))

print("Updated job variable in launcher.mm successfully!")

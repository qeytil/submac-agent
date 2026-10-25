import java.util.*;
import java.util.zip.*;
import java.io.*;

// Mimics what Android apps (APK analyzers, file managers) do with java.util.zip:
// open with ZipFile, iterate, apply Android 14+ ZipPathValidator rule, read every entry;
// then stream the same file with ZipInputStream.
public class ZipCheck {
  public static void main(String[] a) throws Exception {
    int bad = 0;
    try (ZipFile z = new ZipFile(a[0])) {
      Enumeration<? extends ZipEntry> en = z.entries();
      int n = 0; Set<String> seen = new HashSet<>();
      byte[] buf = new byte[65536];
      while (en.hasMoreElements()) {
        ZipEntry e = en.nextElement(); n++;
        String name = e.getName();
        if (name.contains("..") || name.startsWith("/")) { System.out.println("!! Android ZipPathValidator would throw: Invalid zip entry path: " + name); bad++; }
        if (!seen.add(name)) { System.out.println("!! duplicate " + name); bad++; }
        try (InputStream in = z.getInputStream(e)) { while (in.read(buf) > 0) {} }
        catch (Exception ex) { System.out.println("!! read " + name + ": " + ex); bad++; }
      }
      System.out.println("ZipFile entries=" + n);
    } catch (Exception ex) { System.out.println("!! ZipFile open: " + ex); bad++; }
    try (ZipInputStream zi = new ZipInputStream(new FileInputStream(a[0]))) {
      int n = 0; ZipEntry e; byte[] buf = new byte[65536];
      while ((e = zi.getNextEntry()) != null) { n++; while (zi.read(buf) > 0) {} }
      System.out.println("ZipInputStream entries=" + n);
    } catch (Exception ex) { System.out.println("!! ZipInputStream: " + ex); bad++; }
    System.out.println("JAVA_ZIP " + (bad == 0 ? "OK" : "FAIL bad=" + bad));
    System.exit(bad == 0 ? 0 : 1);
  }
}

package app.porter.companion;

import android.content.Context;
import android.os.Build;
import android.os.Environment;
import android.os.StatFs;
import android.os.storage.StorageManager;
import android.os.storage.StorageVolume;
import android.util.JsonReader;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import javax.net.ssl.SSLServerSocket;
import javax.net.ssl.SSLSocket;

/** A small HTTPS implementation of Porter's v1 Wi-Fi protocol. */
final class PorterServer implements Closeable {
    private static final int PORT = 53317;
    private static final int MAX_HEADER_BYTES = 16 * 1024;
    private static final int MAX_BODY_BYTES = 2 * 1024 * 1024;
    private static final int COPY_BUFFER_BYTES = 256 * 1024;

    private final Context context;
    private final TlsIdentity identity;
    private final PairingAuthority pairing;
    private SSLServerSocket socket;
    private ExecutorService workers;

    PorterServer(Context context) throws Exception {
        this.context = context.getApplicationContext();
        this.identity = TlsIdentity.load();
        this.pairing = new PairingAuthority(context);
    }

    synchronized void start() throws Exception {
        if (socket != null) { return; }
        socket = (SSLServerSocket) identity.context().getServerSocketFactory().createServerSocket(PORT);
        socket.setEnabledProtocols(modernProtocols(socket.getSupportedProtocols()));
        workers = Executors.newCachedThreadPool();
        workers.execute(this::acceptLoop);
    }

    int port() { return PORT; }
    String pairingCode() { return pairing.code(); }
    String identityFingerprint() { return identity.fingerprint(); }

    @Override public synchronized void close() {
        if (socket != null) {
            try { socket.close(); } catch (IOException ignored) { }
            socket = null;
        }
        if (workers != null) {
            workers.shutdownNow();
            workers = null;
        }
    }

    private static String[] modernProtocols(String[] supported) {
        List<String> result = new ArrayList<>();
        List<String> available = Arrays.asList(supported);
        if (available.contains("TLSv1.3")) { result.add("TLSv1.3"); }
        if (available.contains("TLSv1.2")) { result.add("TLSv1.2"); }
        return result.toArray(new String[0]);
    }

    private void acceptLoop() {
        while (true) {
            SSLServerSocket current;
            synchronized (this) { current = socket; }
            if (current == null || current.isClosed()) { return; }
            try {
                SSLSocket client = (SSLSocket) current.accept();
                ExecutorService pool;
                synchronized (this) { pool = workers; }
                if (pool == null) { client.close(); return; }
                pool.execute(() -> serve(client));
            } catch (IOException error) {
                if (current.isClosed()) { return; }
            }
        }
    }

    private void serve(SSLSocket client) {
        try (SSLSocket ignored = client) {
            client.setSoTimeout(30_000);
            client.startHandshake();
            try (InputStream input = client.getInputStream(); OutputStream output = client.getOutputStream()) {
                try {
                    dispatch(readRequest(input), output);
                } catch (HttpFailure failure) {
                    writeError(output, failure.status, failure.getMessage());
                } catch (Exception error) {
                    writeError(output, 500, "The companion could not complete that request.");
                }
            }
        } catch (IOException ignored) {
            // A cancelled Mac transfer closes the TLS connection. Nothing is
            // left on the server to report once the peer has gone away.
        }
    }

    private void dispatch(HttpRequest request, OutputStream output) throws Exception {
        URI uri;
        try { uri = URI.create(request.target); }
        catch (IllegalArgumentException error) { throw new HttpFailure(400, "The request path is not valid."); }
        String path = uri.getPath();

        if ("/v1/pair".equals(path)) {
            requireMethod(request, "POST");
            JsonObject body = JsonObject.parse(request.body);
            PairingAuthority.PairingResult result = pairing.pair(body.requiredString("code"));
            if (result.error != null) { throw new HttpFailure(403, result.error); }
            LinkedHashMap<String, String> response = new LinkedHashMap<>();
            response.put("token", result.token);
            response.put("deviceName", deviceName());
            response.put("certificateFingerprint", identity.fingerprint());
            writeJSON(output, 200, jsonObject(response));
            return;
        }

        if (!pairing.authorizes(bearerToken(request.headers.get("authorization")))) {
            throw new HttpFailure(401, "This Mac is not paired with the phone.");
        }
        Map<String, String> query = query(uri.getRawQuery());
        switch (path) {
            case "/v1/info":
                requireMethod(request, "GET");
                writeJSON(output, 200, infoJSON());
                return;
            case "/v1/volumes":
                requireMethod(request, "GET");
                writeJSON(output, 200, volumesJSON());
                return;
            case "/v1/list":
                requireMethod(request, "GET");
                writeJSON(output, 200, listJSON(resolve(requiredQuery(query, "path"))));
                return;
            case "/v1/stat":
                requireMethod(request, "GET");
                writeJSON(output, 200, entryJSON(resolve(requiredQuery(query, "path"))));
                return;
            case "/v1/mkdir":
                requireMethod(request, "POST");
                createDirectory(JsonObject.parse(request.body).requiredString("path"));
                writeEmpty(output, 204);
                return;
            case "/v1/delete":
                requireMethod(request, "POST");
                delete(JsonObject.parse(request.body));
                writeEmpty(output, 204);
                return;
            case "/v1/move":
                requireMethod(request, "POST");
                move(JsonObject.parse(request.body));
                writeEmpty(output, 204);
                return;
            case "/v1/read":
                requireMethod(request, "GET");
                read(resolve(requiredQuery(query, "path")), request.headers.get("range"), output);
                return;
            case "/v1/write":
                requireMethod(request, "PUT");
                write(resolve(requiredQuery(query, "path")), parseLong(requiredQuery(query, "offset")), request.body);
                writeEmpty(output, 204);
                return;
            case "/v1/checksum":
                requireMethod(request, "GET");
                writeJSON(output, 200, checksumJSON(resolve(requiredQuery(query, "path")), requiredQuery(query, "algorithm")));
                return;
            case "/v1/touch":
                requireMethod(request, "POST");
                touch(JsonObject.parse(request.body));
                writeEmpty(output, 204);
                return;
            case "/v1/free":
                requireMethod(request, "GET");
                writeJSON(output, 200, freeJSON(resolve(requiredQuery(query, "path"))));
                return;
            default:
                throw new HttpFailure(404, "That API route does not exist.");
        }
    }

    private String infoJSON() {
        LinkedHashMap<String, String> values = new LinkedHashMap<>();
        values.put("name", deviceName());
        values.put("model", Build.MODEL);
        values.put("manufacturer", Build.MANUFACTURER);
        values.put("androidRelease", Build.VERSION.RELEASE);
        values.put("apiVersion", "v1");
        values.put("hasFullFilesystemAccess", Boolean.toString(Environment.isExternalStorageManager()));
        return jsonObject(values);
    }

    private String deviceName() {
        String manufacturer = Build.MANUFACTURER == null ? "" : Build.MANUFACTURER.trim();
        String model = Build.MODEL == null ? "Android phone" : Build.MODEL.trim();
        return manufacturer.isEmpty() || model.toLowerCase(Locale.ROOT).startsWith(manufacturer.toLowerCase(Locale.ROOT))
                ? model : manufacturer + " " + model;
    }

    private String volumesJSON() throws IOException {
        StringBuilder result = new StringBuilder("[");
        boolean first = true;
        for (StorageRoot root : roots()) {
            if (!first) { result.append(','); }
            first = false;
            StatFs stat = new StatFs(root.path.getPath());
            LinkedHashMap<String, String> values = new LinkedHashMap<>();
            values.put("id", root.path.getPath());
            values.put("name", root.name);
            values.put("path", root.path.getPath());
            values.put("totalBytes", Long.toString(stat.getTotalBytes()));
            values.put("freeBytes", Long.toString(stat.getAvailableBytes()));
            values.put("removable", Boolean.toString(root.removable));
            values.put("filesystem", "unknown");
            result.append(jsonObject(values));
        }
        return result.append(']').toString();
    }

    private String listJSON(File directory) throws Exception {
        if (!directory.exists()) { throw new HttpFailure(404, "That path no longer exists."); }
        if (!directory.isDirectory()) { throw new HttpFailure(409, "That path is not a folder."); }
        File[] files = directory.listFiles();
        if (files == null) { throw new HttpFailure(403, "Android did not allow this folder to be read."); }
        Arrays.sort(files, (left, right) -> left.getName().compareToIgnoreCase(right.getName()));
        StringBuilder result = new StringBuilder("[");
        for (File file : files) {
            // A link out of shared storage must not leak a path in a listing or
            // turn an otherwise safe directory into an escape hatch.
            try { rootContaining(file.getCanonicalFile()); }
            catch (HttpFailure ignored) { continue; }
            if (!firstJSONItem(result)) { result.append(','); }
            result.append(entryJSON(file));
        }
        return result.append(']').toString();
    }

    private String entryJSON(File file) throws Exception {
        if (!file.exists()) { throw new HttpFailure(404, "That path no longer exists."); }
        LinkedHashMap<String, String> values = new LinkedHashMap<>();
        values.put("path", file.getCanonicalPath());
        values.put("size", Long.toString(file.isDirectory() ? 0L : file.length()));
        values.put("modified", Long.toString(file.lastModified() / 1_000L));
        values.put("kind", file.isDirectory() ? "directory" : "file");
        return jsonObject(values);
    }

    private void createDirectory(String requested) throws Exception {
        File directory = resolve(requested);
        if (directory.exists()) { throw new HttpFailure(409, "That folder already exists."); }
        File parent = directory.getParentFile();
        if (parent == null || !parent.isDirectory()) { throw new HttpFailure(404, "The destination folder does not exist."); }
        if (!directory.mkdir()) { throw new HttpFailure(500, "Android could not create that folder."); }
    }

    private void delete(JsonObject body) throws Exception {
        File target = resolve(body.requiredString("path"));
        if (!target.exists()) { throw new HttpFailure(404, "That path no longer exists."); }
        requireMutablePath(target);
        if (target.isDirectory() && !body.booleanValue("recursive", false)) {
            File[] children = target.listFiles();
            if (children != null && children.length > 0) {
                throw new HttpFailure(409, "Refusing to delete a folder that still has files.");
            }
        }
        removeTree(target);
    }

    private void removeTree(File target) throws Exception {
        if (target.isDirectory()) {
            File[] children = target.listFiles();
            if (children == null) { throw new HttpFailure(403, "Android did not allow that folder to be read."); }
            for (File child : children) { removeTree(child); }
        }
        if (!target.delete()) { throw new HttpFailure(500, "Android could not delete that path."); }
    }

    private void move(JsonObject body) throws Exception {
        File from = resolve(body.requiredString("from"));
        File to = resolve(body.requiredString("to"));
        if (!from.exists()) { throw new HttpFailure(404, "The source path no longer exists."); }
        requireMutablePath(from);
        if (to.exists()) { throw new HttpFailure(409, "A file already exists at the destination."); }
        File parent = to.getParentFile();
        if (parent == null || !parent.isDirectory()) { throw new HttpFailure(404, "The destination folder does not exist."); }
        if (!from.renameTo(to)) { throw new HttpFailure(409, "Android could not move that path between these folders."); }
    }

    private void read(File file, String range, OutputStream output) throws Exception {
        if (!file.exists()) { throw new HttpFailure(404, "That path no longer exists."); }
        if (file.isDirectory()) { throw new HttpFailure(409, "That path is a folder."); }
        long length = file.length();
        long offset = rangeOffset(range);
        if (offset < 0 || offset > length || (offset == length && length > 0 && range != null)) {
            throw new HttpFailure(416, "That byte range is outside the file.");
        }
        boolean partial = range != null;
        long remaining = length - offset;
        LinkedHashMap<String, String> headers = new LinkedHashMap<>();
        headers.put("Accept-Ranges", "bytes");
        if (partial) { headers.put("Content-Range", "bytes " + offset + "-" + Math.max(offset, length - 1) + "/" + length); }
        writeHeaders(output, partial ? 206 : 200, "application/octet-stream", remaining, headers);
        try (RandomAccessFile input = new RandomAccessFile(file, "r")) {
            input.seek(offset);
            byte[] buffer = new byte[COPY_BUFFER_BYTES];
            while (remaining > 0) {
                int read = input.read(buffer, 0, (int) Math.min(buffer.length, remaining));
                if (read < 0) { throw new IOException("The file changed while it was being read."); }
                output.write(buffer, 0, read);
                remaining -= read;
            }
            output.flush();
        }
    }

    private void write(File file, long offset, byte[] contents) throws Exception {
        if (offset < 0) { throw new HttpFailure(400, "The write offset must not be negative."); }
        requireMutablePath(file);
        File parent = file.getParentFile();
        if (parent == null || !parent.isDirectory()) { throw new HttpFailure(404, "The destination folder does not exist."); }
        if (contents.length == 0 && !file.exists()) { throw new HttpFailure(404, "There is no partial file to trim."); }
        StatFs stat = new StatFs(rootContaining(file).path.getPath());
        if (contents.length > stat.getAvailableBytes()) {
            throw new HttpFailure(507, "There is not enough free space on this storage volume.");
        }
        try (RandomAccessFile output = new RandomAccessFile(file, "rw")) {
            if (offset > output.length()) { throw new HttpFailure(409, "The write offset is beyond the partial file."); }
            if (contents.length == 0) {
                output.setLength(offset);
            } else {
                output.seek(offset);
                output.write(contents);
            }
        }
    }

    private String checksumJSON(File file, String algorithm) throws Exception {
        if (!file.exists() || file.isDirectory()) { throw new HttpFailure(404, "That file no longer exists."); }
        String digestName;
        if ("sha256".equals(algorithm)) { digestName = "SHA-256"; }
        else if ("md5".equals(algorithm)) { digestName = "MD5"; }
        else { throw new HttpFailure(400, "That checksum algorithm is not supported."); }
        MessageDigest digest = MessageDigest.getInstance(digestName);
        try (InputStream input = new FileInputStream(file)) {
            byte[] buffer = new byte[COPY_BUFFER_BYTES];
            for (int read; (read = input.read(buffer)) >= 0;) { digest.update(buffer, 0, read); }
        }
        LinkedHashMap<String, String> values = new LinkedHashMap<>();
        values.put("algorithm", algorithm);
        values.put("value", TlsIdentity.hex(digest.digest()));
        return jsonObject(values);
    }

    private void touch(JsonObject body) throws Exception {
        File file = resolve(body.requiredString("path"));
        if (!file.exists()) { throw new HttpFailure(404, "That path no longer exists."); }
        requireMutablePath(file);
        if (!file.setLastModified(body.requiredLong("epochSeconds") * 1_000L)) {
            throw new HttpFailure(500, "Android could not set that modification date.");
        }
    }

    private String freeJSON(File path) throws Exception {
        StorageRoot root = rootContaining(path);
        StatFs stat = new StatFs(root.path.getPath());
        LinkedHashMap<String, String> values = new LinkedHashMap<>();
        values.put("totalBytes", Long.toString(stat.getTotalBytes()));
        values.put("freeBytes", Long.toString(stat.getAvailableBytes()));
        return jsonObject(values);
    }

    private File resolve(String requested) throws Exception {
        if (requested == null || !requested.startsWith("/")) {
            throw new HttpFailure(400, "A storage path must be absolute.");
        }
        File path = new File(requested).getCanonicalFile();
        rootContaining(path);
        return path;
    }

    private StorageRoot rootContaining(File path) throws Exception {
        for (StorageRoot root : roots()) {
            String rootPath = root.path.getPath();
            String candidate = path.getPath();
            if (candidate.equals(rootPath) || candidate.startsWith(rootPath + File.separator)) { return root; }
        }
        throw new HttpFailure(403, "That path is outside the phone's shared storage.");
    }

    private void requireMutablePath(File path) throws Exception {
        if (path.getCanonicalFile().equals(rootContaining(path).path)) {
            throw new HttpFailure(403, "A storage volume itself cannot be modified.");
        }
    }

    private List<StorageRoot> roots() throws IOException {
        LinkedHashMap<String, StorageRoot> result = new LinkedHashMap<>();
        File primary = Environment.getExternalStorageDirectory().getCanonicalFile();
        result.put(primary.getPath(), new StorageRoot(primary, "Internal storage", false));
        if (Build.VERSION.SDK_INT >= 30) {
            StorageManager manager = context.getSystemService(StorageManager.class);
            for (StorageVolume volume : manager.getStorageVolumes()) {
                File directory = volume.getDirectory();
                if (directory == null || !directory.exists()) { continue; }
                File canonical = directory.getCanonicalFile();
                result.putIfAbsent(canonical.getPath(), new StorageRoot(
                        canonical, volume.getDescription(context), volume.isRemovable()));
            }
        }
        return new ArrayList<>(result.values());
    }

    private static void requireMethod(HttpRequest request, String expected) throws HttpFailure {
        if (!expected.equals(request.method)) { throw new HttpFailure(405, "That route does not accept this HTTP method."); }
    }

    private static String bearerToken(String header) {
        if (header == null || !header.startsWith("Bearer ")) { return null; }
        return header.substring("Bearer ".length());
    }

    private static Map<String, String> query(String raw) throws HttpFailure {
        if (raw == null || raw.isEmpty()) { return Collections.emptyMap(); }
        HashMap<String, String> values = new HashMap<>();
        for (String pair : raw.split("&")) {
            int split = pair.indexOf('=');
            if (split < 0) { throw new HttpFailure(400, "The query string is not valid."); }
            String key = decodeQueryPart(pair.substring(0, split));
            String value = decodeQueryPart(pair.substring(split + 1));
            values.put(key, value);
        }
        return values;
    }

    private static String decodeQueryPart(String value) throws HttpFailure {
        try { return URLDecoder.decode(value, "UTF-8"); }
        catch (Exception error) { throw new HttpFailure(400, "The query string is not valid UTF-8."); }
    }

    private static String requiredQuery(Map<String, String> values, String key) throws HttpFailure {
        String value = values.get(key);
        if (value == null) { throw new HttpFailure(400, "The " + key + " query value is required."); }
        return value;
    }

    private static long parseLong(String value) throws HttpFailure {
        try { return Long.parseLong(value); }
        catch (NumberFormatException error) { throw new HttpFailure(400, "A numeric value was not valid."); }
    }

    private static long rangeOffset(String range) throws HttpFailure {
        if (range == null) { return 0; }
        if (!range.startsWith("bytes=") || !range.endsWith("-") || range.indexOf(',') >= 0) {
            throw new HttpFailure(416, "Only one open-ended byte range is supported.");
        }
        return parseLong(range.substring("bytes=".length(), range.length() - 1));
    }

    private static HttpRequest readRequest(InputStream input) throws IOException, HttpFailure {
        String requestLine = readLine(input);
        if (requestLine == null) { throw new HttpFailure(400, "The request was empty."); }
        String[] pieces = requestLine.split(" ", 3);
        if (pieces.length != 3 || !pieces[2].startsWith("HTTP/")) {
            throw new HttpFailure(400, "The request line is not valid HTTP.");
        }
        HashMap<String, String> headers = new HashMap<>();
        for (String line; (line = readLine(input)) != null && !line.isEmpty();) {
            int colon = line.indexOf(':');
            if (colon <= 0) { throw new HttpFailure(400, "A request header is not valid."); }
            headers.put(line.substring(0, colon).trim().toLowerCase(Locale.ROOT), line.substring(colon + 1).trim());
        }
        int length = 0;
        if (headers.containsKey("content-length")) {
            try { length = Integer.parseInt(headers.get("content-length")); }
            catch (NumberFormatException error) { throw new HttpFailure(400, "The content length is not valid."); }
        }
        if (length < 0 || length > MAX_BODY_BYTES) { throw new HttpFailure(413, "The request body is too large."); }
        byte[] body = new byte[length];
        int offset = 0;
        while (offset < length) {
            int count = input.read(body, offset, length - offset);
            if (count < 0) { throw new HttpFailure(400, "The request body ended early."); }
            offset += count;
        }
        return new HttpRequest(pieces[0], pieces[1], headers, body);
    }

    private static String readLine(InputStream input) throws IOException, HttpFailure {
        ByteArrayOutputStream line = new ByteArrayOutputStream();
        int next;
        while ((next = input.read()) >= 0) {
            if (next == '\n') { break; }
            if (next != '\r') { line.write(next); }
            if (line.size() > MAX_HEADER_BYTES) { throw new HttpFailure(431, "A request header is too long."); }
        }
        if (next < 0 && line.size() == 0) { return null; }
        return line.toString(StandardCharsets.US_ASCII.name());
    }

    private static void writeError(OutputStream output, int status, String message) throws IOException {
        writeJSON(output, status, jsonObject(Collections.singletonMap("error", message)));
    }

    private static void writeJSON(OutputStream output, int status, String json) throws IOException {
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        writeHeaders(output, status, "application/json", bytes.length, Collections.emptyMap());
        output.write(bytes);
        output.flush();
    }

    private static void writeEmpty(OutputStream output, int status) throws IOException {
        writeHeaders(output, status, null, 0, Collections.emptyMap());
        output.flush();
    }

    private static void writeHeaders(OutputStream output, int status, String type, long length,
                                     Map<String, String> extra) throws IOException {
        StringBuilder header = new StringBuilder("HTTP/1.1 ").append(status).append(' ').append(reason(status)).append("\r\n")
                .append("Connection: close\r\n")
                .append("Content-Length: ").append(length).append("\r\n");
        if (type != null) { header.append("Content-Type: ").append(type).append("\r\n"); }
        for (Map.Entry<String, String> entry : extra.entrySet()) {
            header.append(entry.getKey()).append(": ").append(entry.getValue()).append("\r\n");
        }
        output.write(header.append("\r\n").toString().getBytes(StandardCharsets.US_ASCII));
    }

    private static String reason(int status) {
        switch (status) {
            case 200: return "OK";
            case 204: return "No Content";
            case 206: return "Partial Content";
            case 400: return "Bad Request";
            case 401: return "Unauthorized";
            case 403: return "Forbidden";
            case 404: return "Not Found";
            case 405: return "Method Not Allowed";
            case 409: return "Conflict";
            case 413: return "Payload Too Large";
            case 416: return "Range Not Satisfiable";
            case 431: return "Request Header Fields Too Large";
            case 507: return "Insufficient Storage";
            default: return "Internal Server Error";
        }
    }

    private static String jsonObject(Map<String, String> values) {
        StringBuilder json = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<String, String> entry : values.entrySet()) {
            if (!first) { json.append(','); }
            first = false;
            json.append(quote(entry.getKey())).append(':');
            String value = entry.getValue();
            if (isBooleanField(entry.getKey()) || isNumericField(entry.getKey())) { json.append(value); }
            else { json.append(quote(value)); }
        }
        return json.append('}').toString();
    }

    private static boolean isBooleanField(String key) {
        return "hasFullFilesystemAccess".equals(key) || "removable".equals(key);
    }

    private static boolean isNumericField(String key) {
        return "size".equals(key) || "modified".equals(key) || "totalBytes".equals(key)
                || "freeBytes".equals(key) || "epochSeconds".equals(key);
    }

    private static boolean isInteger(String value) {
        if (value == null || value.isEmpty()) { return false; }
        int index = value.charAt(0) == '-' ? 1 : 0;
        if (index == value.length()) { return false; }
        for (; index < value.length(); index++) { if (!Character.isDigit(value.charAt(index))) { return false; } }
        return true;
    }

    private static boolean firstJSONItem(StringBuilder json) {
        return json.length() == 1;
    }

    private static String quote(String value) {
        StringBuilder quoted = new StringBuilder("\"");
        for (int index = 0; index < value.length(); index++) {
            char character = value.charAt(index);
            switch (character) {
                case '\\': quoted.append("\\\\"); break;
                case '\"': quoted.append("\\\""); break;
                case '\b': quoted.append("\\b"); break;
                case '\f': quoted.append("\\f"); break;
                case '\n': quoted.append("\\n"); break;
                case '\r': quoted.append("\\r"); break;
                case '\t': quoted.append("\\t"); break;
                default:
                    if (character < 0x20) { quoted.append(String.format("\\u%04x", (int) character)); }
                    else { quoted.append(character); }
            }
        }
        return quoted.append('\"').toString();
    }

    private static final class StorageRoot {
        final File path;
        final String name;
        final boolean removable;
        StorageRoot(File path, String name, boolean removable) {
            this.path = path;
            this.name = name == null || name.isEmpty() ? "Storage" : name;
            this.removable = removable;
        }
    }

    private static final class HttpRequest {
        final String method;
        final String target;
        final Map<String, String> headers;
        final byte[] body;
        HttpRequest(String method, String target, Map<String, String> headers, byte[] body) {
            this.method = method;
            this.target = target;
            this.headers = headers;
            this.body = body;
        }
    }

    private static final class HttpFailure extends Exception {
        final int status;
        HttpFailure(int status, String message) { super(message); this.status = status; }
    }

    private static final class JsonObject {
        private final Map<String, String> values;
        private JsonObject(Map<String, String> values) { this.values = values; }

        static JsonObject parse(byte[] bytes) throws IOException, HttpFailure {
            HashMap<String, String> values = new HashMap<>();
            try (JsonReader reader = new JsonReader(new InputStreamReader(
                    new ByteArrayInputStream(bytes), StandardCharsets.UTF_8))) {
                reader.beginObject();
                while (reader.hasNext()) {
                    String key = reader.nextName();
                    switch (reader.peek()) {
                        case STRING: values.put(key, reader.nextString()); break;
                        case NUMBER: values.put(key, reader.nextString()); break;
                        case BOOLEAN: values.put(key, Boolean.toString(reader.nextBoolean())); break;
                        case NULL: reader.nextNull(); break;
                        default: reader.skipValue();
                    }
                }
                reader.endObject();
            } catch (IllegalStateException error) {
                throw new HttpFailure(400, "The JSON request body is not valid.");
            }
            return new JsonObject(values);
        }

        String requiredString(String key) throws HttpFailure {
            String value = values.get(key);
            if (value == null || value.isEmpty()) { throw new HttpFailure(400, "The JSON field " + key + " is required."); }
            return value;
        }

        long requiredLong(String key) throws HttpFailure {
            return parseLong(requiredString(key));
        }

        boolean booleanValue(String key, boolean fallback) {
            String value = values.get(key);
            return value == null ? fallback : Boolean.parseBoolean(value);
        }
    }
}

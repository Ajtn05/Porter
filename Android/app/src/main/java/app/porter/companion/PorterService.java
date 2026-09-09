package app.porter.companion;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Build;
import android.os.Environment;
import android.os.IBinder;

import java.io.IOException;

/** Keeps the local server alive during a copy, then tears down its mDNS record. */
public final class PorterService extends Service {
    public static final String ACTION_START = "app.porter.companion.START";
    public static final String ACTION_STOP = "app.porter.companion.STOP";
    public static final String ACTION_STATUS = "app.porter.companion.STATUS";
    private static final int NOTIFICATION_ID = 53317;
    private static volatile Status status = Status.stopped("Not sharing");

    private PorterServer server;
    private NsdManager nsd;
    private NsdManager.RegistrationListener registration;

    public static final class Status {
        public final boolean running;
        public final String address;
        public final int port;
        public final String code;
        public final String fingerprint;
        public final String message;

        private Status(boolean running, String address, int port, String code, String fingerprint, String message) {
            this.running = running;
            this.address = address;
            this.port = port;
            this.code = code;
            this.fingerprint = fingerprint;
            this.message = message;
        }

        static Status running(String address, int port, String code, String fingerprint) {
            return new Status(true, address, port, code, fingerprint, "Sharing");
        }

        static Status stopped(String message) {
            return new Status(false, "", 0, "", "", message);
        }
    }

    public static Status snapshot() { return status; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_START : intent.getAction();
        if (ACTION_STOP.equals(action)) {
            stopSharing();
            stopSelf();
        } else {
            startSharing();
        }
        return START_NOT_STICKY;
    }

    @Override public void onDestroy() {
        stopSharing();
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) { return null; }

    private synchronized void startSharing() {
        if (server != null) { return; }
        if (!Environment.isExternalStorageManager()) {
            publish(Status.stopped("Allow file access before starting sharing."));
            stopSelf();
            return;
        }
        try {
            server = new PorterServer(this);
            server.start();
            String address = NetworkAddresses.firstIPv4();
            if (address == null) {
                throw new IOException("No Wi-Fi or local-network address is available.");
            }
            startForeground(NOTIFICATION_ID, notification("Sharing on " + address + ":" + server.port()));
            advertise(server.port());
            publish(Status.running(address, server.port(), server.pairingCode(), server.identityFingerprint()));
        } catch (Exception error) {
            if (server != null) { server.close(); server = null; }
            publish(Status.stopped(error.getMessage() == null ? "Could not start sharing." : error.getMessage()));
            stopSelf();
        }
    }

    private synchronized void stopSharing() {
        if (registration != null && nsd != null) {
            try { nsd.unregisterService(registration); } catch (IllegalArgumentException ignored) { }
        }
        registration = null;
        nsd = null;
        if (server != null) { server.close(); server = null; }
        stopForeground(STOP_FOREGROUND_REMOVE);
        publish(Status.stopped("Not sharing"));
    }

    private void advertise(int port) {
        nsd = (NsdManager) getSystemService(Context.NSD_SERVICE);
        NsdServiceInfo service = new NsdServiceInfo();
        service.setServiceName("Porter " + Build.MODEL);
        service.setServiceType("_porter._tcp.");
        service.setPort(port);
        service.setAttribute("id", server.identityFingerprint().substring(0, 24));
        service.setAttribute("name", Build.MODEL);
        service.setAttribute("version", "1");
        registration = new NsdManager.RegistrationListener() {
            @Override public void onServiceRegistered(NsdServiceInfo info) { }
            @Override public void onRegistrationFailed(NsdServiceInfo info, int code) { }
            @Override public void onServiceUnregistered(NsdServiceInfo info) { }
            @Override public void onUnregistrationFailed(NsdServiceInfo info, int code) { }
        };
        nsd.registerService(service, NsdManager.PROTOCOL_DNS_SD, registration);
    }

    private Notification notification(String content) {
        String channelID = "porter-sharing";
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(
                channelID, "Porter sharing", NotificationManager.IMPORTANCE_LOW));
        return new Notification.Builder(this, channelID)
                .setSmallIcon(R.drawable.ic_stat_porter)
                .setContentTitle("Porter Companion is sharing")
                .setContentText(content)
                .setOngoing(true)
                .build();
    }

    private void publish(Status next) {
        status = next;
        sendBroadcast(new Intent(ACTION_STATUS).setPackage(getPackageName()));
    }
}

package app.porter.companion;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.StatusBarManager;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.Icon;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsetsController;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Space;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Consumer;

/** The user-facing switchboard for Porter's local file server. */
public final class MainActivity extends Activity {
    private static final int INK = Color.rgb(23, 48, 73);
    private static final int MUTED = Color.rgb(94, 111, 132);
    private static final int BACKGROUND = Color.rgb(247, 250, 253);
    private static final int SURFACE = Color.WHITE;
    private static final int PRIMARY = Color.rgb(37, 99, 235);
    private static final int PRIMARY_SURFACE = Color.rgb(235, 243, 255);
    private static final int SUCCESS = Color.rgb(20, 142, 101);
    private static final int SUCCESS_SURFACE = Color.rgb(233, 248, 240);
    private static final int ALERT = Color.rgb(197, 87, 55);
    private static final int ALERT_SURFACE = Color.rgb(255, 242, 237);

    private LinearLayout statusCard;
    private LinearLayout connectionCard;
    private View statusDot;
    private TextView statusTitle;
    private TextView statusDetail;
    private TextView accessDetail;
    private TextView endpointValue;
    private TextView codeValue;
    private TextView fingerprintValue;
    private TextView tileDetail;
    private Button primaryButton;
    private Button accessButton;

    private final BroadcastReceiver statusReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) { refresh(); }
    };

    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(INK);
        getWindow().setNavigationBarColor(BACKGROUND);
        setContentView(makeContent());

        // Some Android 16 builds do not create the decor view until content is attached.
        // Asking for the insets controller earlier crashes during activity launch.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            WindowInsetsController controller = getWindow().getInsetsController();
            if (controller != null) {
                controller.setSystemBarsAppearance(
                        WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                        WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
                );
            }
        }
        requestRuntimePermissions();
    }

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    @Override public void onResume() {
        super.onResume();
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(statusReceiver, new IntentFilter(PorterService.ACTION_STATUS), RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(statusReceiver, new IntentFilter(PorterService.ACTION_STATUS));
        }
        refresh();
    }

    @Override public void onPause() {
        unregisterReceiver(statusReceiver);
        super.onPause();
    }

    private View makeContent() {
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(22), dp(34), dp(22), dp(24));

        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(BACKGROUND);
        scroll.addView(content);

        ImageView headerIcon = new ImageView(this);
        headerIcon.setImageResource(R.drawable.ic_porter_mark);
        LinearLayout headerText = new LinearLayout(this);
        headerText.setOrientation(LinearLayout.VERTICAL);
        headerText.addView(text("Porter Companion", 21, INK, Typeface.BOLD));
        TextView subtitle = text(
                "Browse and transfer this phone's shared files from Porter on your Mac.",
                13, MUTED, Typeface.NORMAL
        );
        subtitle.setLineSpacing(dp(2), 1f);
        headerText.addView(subtitle, matchParent(3));

        LinearLayout header = new LinearLayout(this);
        header.setGravity(Gravity.CENTER_VERTICAL);
        header.addView(headerIcon, new LinearLayout.LayoutParams(dp(46), dp(46)));
        header.addView(horizontalSpace(12));
        header.addView(headerText, new LinearLayout.LayoutParams(
                0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f
        ));
        content.addView(header, matchParent());
        content.addView(verticalSpace(24));

        statusCard = new LinearLayout(this);
        statusCard.setOrientation(LinearLayout.VERTICAL);
        statusCard.setPadding(dp(16), dp(14), dp(16), dp(14));
        LinearLayout statusTop = new LinearLayout(this);
        statusTop.setGravity(Gravity.CENTER_VERTICAL);
        statusDot = new View(this);
        statusTop.addView(statusDot, new LinearLayout.LayoutParams(dp(8), dp(8)));
        statusTop.addView(horizontalSpace(9));
        statusTitle = text("", 15, INK, Typeface.BOLD);
        statusTop.addView(statusTitle, new LinearLayout.LayoutParams(
                0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f
        ));
        statusCard.addView(statusTop);
        statusDetail = text("", 13, MUTED, Typeface.NORMAL);
        statusDetail.setLineSpacing(dp(2), 1f);
        statusCard.addView(statusDetail, matchParent(6));
        content.addView(statusCard, matchParent());
        content.addView(verticalSpace(14));

        primaryButton = button("", PRIMARY, Color.WHITE, null);
        primaryButton.setOnClickListener(view -> toggleSharing());
        content.addView(primaryButton, matchParent(0, 48));

        accessDetail = text(
                "Porter needs Android's shared-storage permission before a paired Mac can browse files.",
                12, MUTED, Typeface.NORMAL
        );
        accessDetail.setLineSpacing(dp(2), 1f);
        content.addView(accessDetail, matchParent(9));
        accessButton = button("Allow file access", SURFACE, PRIMARY, PRIMARY);
        accessButton.setOnClickListener(view -> openAllFilesAccess());
        content.addView(accessButton, matchParent(10, 46));

        content.addView(verticalSpace(24));
        content.addView(sectionLabel("PAIR THIS PHONE"));
        content.addView(text("Connection details", 16, INK, Typeface.BOLD), matchParent(6));
        TextView connectionHint = text(
                "In Porter on your Mac, choose Pair Wi-Fi Phone and copy these values exactly.",
                13, MUTED, Typeface.NORMAL
        );
        connectionHint.setLineSpacing(dp(2), 1f);
        content.addView(connectionHint, matchParent(5));
        connectionCard = new LinearLayout(this);
        connectionCard.setOrientation(LinearLayout.VERTICAL);
        connectionCard.setPadding(dp(15), dp(13), dp(15), dp(13));
        connectionCard.setBackground(rounded(SURFACE, 14, Color.rgb(207, 220, 234)));
        endpointValue = detailRow(connectionCard, "ADDRESS");
        codeValue = detailRow(connectionCard, "SIX-DIGIT CODE");
        fingerprintValue = detailRow(connectionCard, "CERTIFICATE FINGERPRINT");
        content.addView(connectionCard, matchParent(12));

        content.addView(verticalSpace(24));
        content.addView(sectionLabel("QUICK SETTINGS"));
        content.addView(text("Keep sharing one swipe away", 16, INK, Typeface.BOLD), matchParent(6));
        tileDetail = text(
                "Add the Porter sharing tile to start or stop the local server without reopening this app.",
                13, MUTED, Typeface.NORMAL
        );
        tileDetail.setLineSpacing(dp(2), 1f);
        content.addView(tileDetail, matchParent(5));
        Button tileButton = button("Add to Quick Settings", INK, Color.WHITE, null);
        tileButton.setOnClickListener(view -> requestQuickSettingsTile());
        content.addView(tileButton, matchParent(12, 46));

        content.addView(verticalSpace(24));
        TextView note = text(
                "Sharing stays on your local network. No files, account details, or pairing tokens leave your devices.",
                12, MUTED, Typeface.NORMAL
        );
        note.setGravity(Gravity.CENTER_HORIZONTAL);
        note.setLineSpacing(dp(2), 1f);
        content.addView(note, matchParent());
        return scroll;
    }

    private TextView detailRow(LinearLayout container, String label) {
        TextView labelView = text(label, 10, MUTED, Typeface.BOLD);
        labelView.setLetterSpacing(0.08f);
        container.addView(labelView, matchParent(container.getChildCount() == 0 ? 0 : 12));
        TextView value = text("", 14, INK, Typeface.BOLD);
        value.setTypeface(Typeface.MONOSPACE, Typeface.NORMAL);
        value.setTextIsSelectable(true);
        value.setLineSpacing(dp(2), 1f);
        container.addView(value, matchParent(3));
        return value;
    }

    private void toggleSharing() {
        if (PorterService.snapshot().running) {
            startService(new Intent(this, PorterService.class).setAction(PorterService.ACTION_STOP));
            return;
        }
        if (!Environment.isExternalStorageManager()) {
            openAllFilesAccess();
            return;
        }
        Intent intent = new Intent(this, PorterService.class).setAction(PorterService.ACTION_START);
        startForegroundService(intent);
    }

    private void openAllFilesAccess() {
        Intent intent = new Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:" + getPackageName())
        );
        startActivity(intent);
    }

    private void refresh() {
        boolean permitted = Environment.isExternalStorageManager();
        PorterService.Status current = PorterService.snapshot();
        if (!permitted) {
            showStatus(
                    "File access needed",
                    "Allow shared-storage access before this phone can be browsed from Porter.",
                    ALERT, ALERT_SURFACE
            );
            primaryButton.setText("Allow file access");
            primaryButton.setBackground(rounded(PRIMARY, 14, null));
            accessDetail.setVisibility(View.VISIBLE);
            accessButton.setVisibility(View.VISIBLE);
            connectionCard.setVisibility(View.GONE);
            return;
        }

        accessDetail.setVisibility(View.GONE);
        accessButton.setVisibility(View.GONE);
        if (current.running) {
            showStatus(
                    "Sharing is on",
                    "A paired Mac can browse and transfer files while this local server stays active.",
                    SUCCESS, SUCCESS_SURFACE
            );
            primaryButton.setText("Turn off sharing");
            primaryButton.setBackground(rounded(INK, 14, null));
            endpointValue.setText(current.address + ":" + current.port);
            codeValue.setText(current.code);
            fingerprintValue.setText(groupFingerprint(current.fingerprint));
            connectionCard.setVisibility(View.VISIBLE);
        } else {
            showStatus(
                    "Sharing is off",
                    "Turn it on whenever you want this phone to appear in Porter on your Mac.",
                    MUTED, SURFACE
            );
            primaryButton.setText("Turn on sharing");
            primaryButton.setBackground(rounded(PRIMARY, 14, null));
            connectionCard.setVisibility(View.GONE);
        }
    }

    private void showStatus(String title, String detail, int dot, int surface) {
        statusTitle.setText(title);
        statusDetail.setText(detail);
        statusCard.setBackground(rounded(surface, 14, null));
        statusDot.setBackground(oval(dot));
    }

    private String groupFingerprint(String fingerprint) {
        StringBuilder grouped = new StringBuilder(fingerprint.length() + fingerprint.length() / 4);
        for (int index = 0; index < fingerprint.length(); index++) {
            if (index > 0 && index % 4 == 0) { grouped.append(' '); }
            grouped.append(fingerprint.charAt(index));
        }
        return grouped.toString();
    }

    private void requestQuickSettingsTile() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            tileDetail.setText("Swipe down twice, tap Edit, then add Porter sharing to Quick Settings.");
            return;
        }
        StatusBarManager manager = getSystemService(StatusBarManager.class);
        manager.requestAddTileService(
                new ComponentName(this, PorterTileService.class),
                "Porter sharing",
                Icon.createWithResource(this, R.drawable.ic_stat_porter),
                getMainExecutor(),
                new Consumer<Integer>() {
                    @Override public void accept(Integer result) {
                        if (result == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED) {
                            tileDetail.setText("Porter sharing is now in Quick Settings.");
                        } else if (result == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED) {
                            tileDetail.setText("Porter sharing is already in Quick Settings.");
                        } else {
                            tileDetail.setText("You can add Porter sharing later from the Quick Settings edit screen.");
                        }
                    }
                }
        );
    }

    private void requestRuntimePermissions() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) { return; }
        List<String> needed = new ArrayList<>();
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            needed.add(Manifest.permission.POST_NOTIFICATIONS);
        }
        if (checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES) != PackageManager.PERMISSION_GRANTED) {
            needed.add(Manifest.permission.NEARBY_WIFI_DEVICES);
        }
        if (!needed.isEmpty()) {
            requestPermissions(needed.toArray(new String[0]), 1);
        }
    }

    private TextView text(String value, int sp, int color, int style) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(sp);
        view.setTextColor(color);
        view.setTypeface(Typeface.create(Typeface.DEFAULT, style));
        view.setGravity(Gravity.START);
        return view;
    }

    private TextView sectionLabel(String value) {
        TextView label = text(value, 10, MUTED, Typeface.BOLD);
        label.setLetterSpacing(0.1f);
        return label;
    }

    private Button button(String label, int background, int textColor, Integer stroke) {
        Button button = new Button(this);
        button.setText(label);
        button.setTextSize(15);
        button.setTextColor(textColor);
        button.setTypeface(Typeface.DEFAULT_BOLD);
        button.setAllCaps(false);
        button.setMinHeight(0);
        button.setMinimumHeight(0);
        button.setPadding(dp(18), 0, dp(18), 0);
        button.setBackground(rounded(background, 14, stroke));
        return button;
    }

    private GradientDrawable rounded(int color, int radius, Integer stroke) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(color);
        drawable.setCornerRadius(dp(radius));
        if (stroke != null) { drawable.setStroke(dp(1), stroke); }
        return drawable;
    }

    private GradientDrawable oval(int color) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setShape(GradientDrawable.OVAL);
        drawable.setColor(color);
        return drawable;
    }

    private Space verticalSpace(int height) {
        Space space = new Space(this);
        space.setMinimumHeight(dp(height));
        return space;
    }

    private Space horizontalSpace(int width) {
        Space space = new Space(this);
        space.setMinimumWidth(dp(width));
        return space;
    }

    private LinearLayout.LayoutParams matchParent() {
        return matchParent(0, LinearLayout.LayoutParams.WRAP_CONTENT);
    }

    private LinearLayout.LayoutParams matchParent(int top) {
        return matchParent(top, LinearLayout.LayoutParams.WRAP_CONTENT);
    }

    private LinearLayout.LayoutParams matchParent(int top, int height) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                height > 0 ? dp(height) : height
        );
        params.topMargin = dp(top);
        return params;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}

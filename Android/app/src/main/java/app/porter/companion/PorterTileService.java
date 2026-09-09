package app.porter.companion;

import android.content.Intent;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

/** Keeps the local server one swipe away without exposing a second control path. */
public final class PorterTileService extends TileService {
    @Override public void onStartListening() { updateTile(); }

    @Override public void onClick() {
        boolean running = PorterService.snapshot().running;
        Intent intent = new Intent(this, PorterService.class).setAction(
                running ? PorterService.ACTION_STOP : PorterService.ACTION_START
        );
        if (running) { startService(intent); }
        else { startForegroundService(intent); }
        updateTile(!running);
    }

    private void updateTile() {
        updateTile(PorterService.snapshot().running);
    }

    private void updateTile(boolean running) {
        Tile tile = getQsTile();
        if (tile == null) { return; }
        tile.setState(running ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.setStateDescription(running ? "On - sharing files" : "Off");
        tile.setContentDescription("Porter sharing: " + (running ? "on" : "off"));
        tile.updateTile();
    }
}

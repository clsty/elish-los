package com.framecheck;

import android.app.Activity;
import android.content.Context;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * One job: log the orientation-family sensors exactly as the framework publishes them, so
 * a host script can check the cross-type identity gravity_device = R(Q)^T * (0,0,|g|) (the
 * self-consistency check in docs/orientation.md). The transpose is not a detail: R maps
 * device -> world in AOSP's definition, so getting the device frame needs R^T.
 *
 * Why nothing is computed here: what the check needs is precisely the numbers the
 * framework hands an app. Computing them again in the app would replace the thing under
 * test. So this class subscribes, caches, and prints one snapshot every 400 ms, and does
 * no coordinate transformation of any kind.
 *
 * A type can have two sensors (a vendor-fused one and the AOSP virtual one). All of them
 * are subscribed, each in its own field: both must predict the same gravity, which is one
 * of the things being verified.
 */
public class FrameCheck extends Activity implements SensorEventListener {
    private static final String TAG = "FrameCheck";
    private static final int TICK_MS = 400;

    // Three families: vector-type (accel / uncalibrated / gyro / mag), the virtual types
    // derived from them, quaternion types, and the enumerated Euler-angle type.
    private static final int[] TYPES = {
            Sensor.TYPE_ACCELEROMETER,                  // 1
            Sensor.TYPE_ACCELEROMETER_UNCALIBRATED,     // 35  bias must rotate with vector
            Sensor.TYPE_GYROSCOPE,                      // 4
            Sensor.TYPE_GYROSCOPE_UNCALIBRATED,         // 16
            Sensor.TYPE_MAGNETIC_FIELD,                 // 2
            Sensor.TYPE_GRAVITY,                        // 9
            Sensor.TYPE_ROTATION_VECTOR,                // 11  the main quaternion type
            Sensor.TYPE_GAME_ROTATION_VECTOR,           // 15
            Sensor.TYPE_GEOMAGNETIC_ROTATION_VECTOR,    // 20
            Sensor.TYPE_ORIENTATION,                    // 3  the reconstruct-then-extract path
    };

    private static final class Slot {
        final String key;
        final Sensor sensor;
        final float[] v = new float[8];
        long lastTs = 0;

        Slot(String key, Sensor sensor) {
            this.key = key;
            this.sensor = sensor;
        }
    }

    private final List<Slot> slots = new ArrayList<>();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private SensorManager sm;
    private String probeSummary = "";
    private int ticks = 0;

    private final Runnable ticker = new Runnable() {
        @Override
        public void run() {
            dump();
            handler.postDelayed(this, TICK_MS);
        }
    };

    private static String tag(Sensor s, int idx) {
        String n = s.getName().replace(' ', '_').replace('|', '_');
        String v = s.getVendor().replace(' ', '_').replace('|', '_');
        return s.getType() + "#" + idx + ":" + n + ":" + v;
    }

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        sm = (SensorManager) getSystemService(Context.SENSOR_SERVICE);
        int total = 0;
        for (int type : TYPES) {
            List<Sensor> list = sm.getSensorList(type);
            for (int i = 0; i < list.size(); i++) {
                slots.add(new Slot(tag(list.get(i), i), list.get(i)));
                total++;
            }
            Log.i(TAG, "PROBE|" + type + "|" + list.size());
        }
        Log.i(TAG, "BEGIN|slots=" + total + "|period_ms=" + TICK_MS);
    }

    /** The probe counts logged in onCreate are easily pushed out of the 256 KiB main
     *  buffer, so they are repeated with the snapshots. */
    private String probes() {
        StringBuilder sb = new StringBuilder();
        for (int type : TYPES) {
            int n = 0;
            for (Slot slot : slots) {
                if (slot.sensor.getType() == type) {
                    n++;
                }
            }
            if (sb.length() > 0) {
                sb.append(' ');
            }
            sb.append(type).append(':').append(n);
        }
        return sb.toString();
    }

    @Override
    protected void onResume() {
        super.onResume();
        for (Slot slot : slots) {
            sm.registerListener(this, slot.sensor, SensorManager.SENSOR_DELAY_NORMAL);
        }
        handler.postDelayed(ticker, TICK_MS);
    }

    @Override
    protected void onPause() {
        handler.removeCallbacks(ticker);
        sm.unregisterListener(this);
        Log.i(TAG, "END");
        super.onPause();
    }

    @Override
    public void onSensorChanged(SensorEvent event) {
        for (Slot slot : slots) {
            if (slot.sensor == event.sensor) {
                int n = Math.min(event.values.length, slot.v.length);
                System.arraycopy(event.values, 0, slot.v, 0, n);
                slot.lastTs = event.timestamp;
                break;
            }
        }
    }

    @Override
    public void onAccuracyChanged(Sensor sensor, int accuracy) {
    }

    private void dump() {
        ticks += 1;
        if (ticks == 1 || ticks % 25 == 0) {
            Log.i(TAG, "PROBESUM|" + probes());
        }
        StringBuilder sb = new StringBuilder("SNAP");
        for (Slot slot : slots) {
            if (slot.lastTs == 0) {
                continue;
            }
            sb.append('|').append(slot.key).append('=');
            for (int i = 0; i < 8; i++) {
                if (i > 0) {
                    sb.append(',');
                }
                sb.append(String.format(Locale.US, "%.5f", slot.v[i]));
            }
        }
        Log.i(TAG, sb.toString());
    }
}

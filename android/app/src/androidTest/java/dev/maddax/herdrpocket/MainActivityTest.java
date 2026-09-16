package dev.maddax.herdrpocket;

import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.Parameterized;
import org.junit.runners.Parameterized.Parameters;
import pl.leancode.patrol.PatrolJUnitRunner;

/**
 * The native half of every test in {@code patrol_test/}.
 *
 * <p>WHY THIS FILE EXISTS AT ALL. Patrol tests are Dart, but they are RUN by
 * Android's instrumentation framework — that is the whole point of Patrol, and
 * it is what lets a test tap a system permission dialog that Flutter cannot
 * see. Something on the Java side has to be the JUnit entry point, and this is
 * it: {@code Parameterized} is what turns "one Dart test" into "one JUnit test
 * per Dart test", so Android Test Orchestrator gives each of them a fresh
 * process and a fresh app install-state.
 *
 * <p>WHAT IT DOES, IN THREE STEPS, because the order is the mechanism:
 * <ol>
 *   <li>{@code setUp(MainActivity.class)} — tells Patrol which Activity to
 *       launch before each test. {@code MainActivity} is ours, not
 *       {@code FlutterActivity}, because the manifest declares
 *       {@code .MainActivity} and it is the one that registers the SAF
 *       {@code MethodChannel}. A test that drove a bare {@code FlutterActivity}
 *       would exercise an app whose directory picker is not wired up.
 *   <li>{@code waitForPatrolAppService()} — blocks until the Dart side is
 *       listening. Skipping this is the classic symptom of "the very first test
 *       fails and the rest pass": {@code listDartTests()} is called before the
 *       app has anything to answer with.
 *   <li>{@code listDartTests()} — the names of the tests in
 *       {@code patrol_test/}, one JUnit parameter each.
 * </ol>
 *
 * <p>NOTHING HERE SHOULD EVER NEED EDITING when Dart tests are added or
 * removed: the list is discovered from the running app, not written down.
 */
@RunWith(Parameterized.class)
public class MainActivityTest {

    @Parameters(name = "{0}")
    public static Object[] testCases() {
        PatrolJUnitRunner instrumentation =
                (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        instrumentation.setUp(MainActivity.class);
        instrumentation.waitForPatrolAppService();
        return instrumentation.listDartTests();
    }

    private final String dartTestName;

    public MainActivityTest(String dartTestName) {
        this.dartTestName = dartTestName;
    }

    @Test
    public void runDartTest() {
        PatrolJUnitRunner instrumentation =
                (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        instrumentation.runDartTest(dartTestName);
    }
}

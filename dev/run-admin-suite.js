const path = require('path');
const { runSuite, printSummary } = require('../modules/Crest/tests/playwright/harness/run-suite');
const { loginAsAdmin } = require('../modules/Crest/tests/playwright/harness/auth');
const { buildSharedAdminChecks } = require('../modules/Crest/tests/playwright/run-admin-suite');

// The host's admin suite entry: the shared Crest checks and the Crest modules' checks, in
// one browser instance and one login.
function buildChecks() {
  return [
    ...buildSharedAdminChecks(),
    { name: 'parties-contacts-api', fn: require('../modules/Crest/Crest.Parties/tests/playwright/checks/party-contacts-api') },
    { name: 'parties-positions-api', fn: require('../modules/Crest/Crest.Parties/tests/playwright/checks/party-positions-api') },
    { name: 'workflows-api', fn: require('../modules/Crest/Crest.Workflows/tests/playwright/checks/workflows-api') },
    { name: 'workflows-platform-activities', fn: require('../modules/Crest/Crest.Workflows/tests/playwright/checks/workflows-platform-activities') },
    { name: 'workflows-units', fn: require('../modules/Crest/Crest.Workflows/tests/playwright/checks/workflows-units') },
    { name: 'workflows-approvals', fn: require('../modules/Crest/Crest.Workflows/tests/playwright/checks/workflows-approvals') },
    { name: 'workflows-designer', fn: require('../modules/Crest/Crest.Workflows/tests/playwright/checks/workflows-designer') },
    { name: 'members-portal-api', fn: require('../modules/Crest/Crest.Members/tests/playwright/checks/members-portal-api') },
    { name: 'content-groups-api', fn: require('../modules/Crest/tests/playwright/checks/content-groups-api') },
  ];
}

async function main() {
  const baseUrl = process.env.BASE_URL || 'http://crest.localhost:5014';
  // The host's own screenshot baselines. The admin shell shows the modules THIS host
  // enables, so its dashboard cannot match the submodule's checked-in baseline; writing
  // into the submodule's output/ would also be a change to a repository this one only
  // consumes.
  const outputRoot = process.env.OUTPUT_ROOT || path.join(__dirname, 'playwright-output');

  // CHECK_FILTER=<substring> runs only matching checks (the health gate's provisioning
  // wait is still paid; useful for iterating on one check).
  const filter = process.env.CHECK_FILTER;
  const checks = filter
    ? buildChecks().filter(check => check.name.includes(filter))
    : buildChecks();

  const results = await runSuite({
    baseUrl,
    login: loginAsAdmin,
    checks,
    outputRoot,
  });

  if (process.env.VERBOSE) {
    for (const r of results) {
      console.log(`${r.pass === false ? 'FAIL' : 'ok  '} ${r.suite} :: ${r.name} — ${r.message || ''}`);
    }
  }

  const ok = printSummary(results);
  process.exit(ok ? 0 : 1);
}

main();

// enact-probe on a macOS agent labelled 'xcode'. Stages call the same scripts as GitHub Actions.
pipeline {
  agent { label 'xcode' }
  options { timestamps(); timeout(time: 60, unit: 'MINUTES') }
  stages {
    stage('Toolchain') { steps { sh 'sw_vers && xcodebuild -version && swift --version' } }
    stage('XCTest + protocol + fault matrix') {
      steps { sh 'scripts/ci/unit.sh' }
      post { always { junit allowEmptyResults: true, testResults: 'build/reports/pytest.xml' } }
    }
    stage('XCUITest (iPhone)') {
      // One simulator session at a time per agent: the servers bind fixed ports 8770/8771.
      steps { lock('enact-ports') { sh 'scripts/ci/ui.sh' } }
    }
  }
  post { always { archiveArtifacts allowEmptyArchive: true, artifacts: 'build/reports/**' } }
}

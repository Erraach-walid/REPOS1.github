'use strict'

const downloadFileFromGithub = require('./download-file-from-github')
const electronInstaller = require('electron-winstaller')
const fs = require('fs-extra')
const glob = require('glob')
const os = require('os')
const path = require('path')

const CONFIG = require('../config')

module.exports = function (packagedAppPath, codeSign) {
  const options = {
    appDirectory: packagedAppPath,
    authors: 'GitHub Inc.',
    iconUrl: `https://raw.githubusercontent.com/atom/atom/master/resources/app-icons/${CONFIG.channel}/atom.ico`,
    loadingGif: path.join(CONFIG.repositoryRootPath, 'resources', 'win', 'loading.gif'),
    outputDirectory: CONFIG.buildOutputPath,
    remoteReleases: `https://atom.io/api/updates?version=${CONFIG.appMetadata.version}`,
    setupIcon: path.join(CONFIG.repositoryRootPath, 'resources', 'app-icons', CONFIG.channel, 'atom.ico')
  }

  const certPath = path.join(os.tmpdir(), 'win.p12')
  if (codeSign && process.env.WIN_P12KEY_URL) {
    downloadFileFromGithub(process.env.WIN_P12KEY_URL, certPath)
    options.certificateFile = certPath
    options.certificatePassword = process.env.WIN_P12KEY_PASSWORD
  } else {
    console.log('Skipping code-signing. Specify the --code-sign option and provide a WIN_P12KEY_URL environment variable to perform code-signing'.gray)
  }

  const cleanUp = function () {
    if (fs.existsSync(certPath)) {
      console.log(`Deleting certificate at ${certPath}`)
      fs.removeSync(certPath)
    }

    for (let nupkgPath of glob.sync(`${CONFIG.buildOutputPath}/*.nupkg`)) {
      if (!nupkgPath.includes(CONFIG.appMetadata.version)) {
        console.log(`Deleting downloaded nupkg for previous version at ${nupkgPath} to prevent it from being stored as an artifact`)
        fs.removeSync(nupkgPath)
      }
    }
  }
  console.log(`Creating Windows Installer for ${packagedAppPath}`)
  return electronInstaller.createWindowsInstaller(options).then(cleanUp, function (error) {
    console.log(`Windows installer creation failed:\n${error}`)
    cleanUp()
  })
}

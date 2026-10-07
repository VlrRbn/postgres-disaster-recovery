#!/usr/bin/env python3
"""Prepare an ignored pgBackRest S3 secret from an AWS CLI credential profile."""

import argparse
import configparser
import io
import json
import os
import re
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def validate_settings(settings):
    bucket = settings['bucket']
    if (not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', bucket)
            or '..' in bucket or re.fullmatch(r'[0-9.]+', bucket)):
        raise ValueError('Use a valid general-purpose S3 bucket name')
    region = settings['region']
    if not re.fullmatch(r'[a-z]{2}-[a-z]+-[1-9][0-9]*', region) or region.startswith('cn-'):
        raise ValueError('Use a commercial AWS region, for example eu-west-1')
    if not re.fullmatch(r'postgres-dr/[a-z0-9][a-z0-9/-]*', settings['prefix']):
        raise ValueError('Prefix must start with postgres-dr/ and use lowercase letters, digits, slashes or hyphens')
    if settings['prefix'].endswith('/') or '//' in settings['prefix']:
        raise ValueError('Prefix must not end with / or contain //')
    if not settings['profile'] or any(char in settings['profile'] for char in '\r\n'):
        raise ValueError('An AWS CLI profile name is required')
    if settings.get('role_arn') and not re.fullmatch(
            r'arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+', settings['role_arn']):
        raise ValueError('Use an IAM role ARN for the S3 writer identity')
    return settings


def build_config(settings, credentials, *, now=None):
    validate_settings(settings)
    for name in ('AccessKeyId', 'SecretAccessKey'):
        value = credentials.get(name)
        if not isinstance(value, str) or not value or any(char.isspace() for char in value):
            raise ValueError(f'Credential field {name} is missing or invalid')
    token = credentials.get('SessionToken')
    if token is not None and (not isinstance(token, str) or not token
                              or any(char.isspace() for char in token)):
        raise ValueError('Session token is invalid')
    if credentials.get('Expiration'):
        expires = datetime.fromisoformat(credentials['Expiration'])
        if expires.utcoffset() is None or expires <= (now or datetime.now(timezone.utc)):
            raise ValueError('AWS credentials have expired or have no timezone; refresh the profile')

    config = configparser.ConfigParser(interpolation=None)
    base = Path(__file__).resolve().parent.parent / 'pgbackrest/pgbackrest.conf'
    config.read_string(base.read_text())
    config['global'].update({
        'repo1-type': 's3', 'repo1-path': f"/{settings['prefix']}", 'repo1-bundle': 'y',
        'repo1-s3-bucket': settings['bucket'], 'repo1-s3-region': settings['region'],
        'repo1-s3-endpoint': f"s3.{settings['region']}.amazonaws.com",
        'repo1-s3-uri-style': 'path', 'repo1-s3-key-type': 'shared', 'repo1-storage-verify-tls': 'y',
        'repo1-s3-key': credentials['AccessKeyId'], 'repo1-s3-key-secret': credentials['SecretAccessKey'],
    })
    if token:
        config['global']['repo1-s3-token'] = token
    output = io.StringIO()
    config.write(output, space_around_delimiters=False)
    return output.getvalue()


def writer_policy(settings):
    validate_settings(settings)
    bucket = f"arn:aws:s3:::{settings['bucket']}"
    prefix = settings['prefix']
    return {'Version': '2012-10-17', 'Statement': [
        {'Sid': 'ListRepositoryPrefix', 'Effect': 'Allow', 'Action': ['s3:ListBucket'],
         'Resource': bucket, 'Condition': {'StringLike': {'s3:prefix': [prefix, prefix + '/*']}}},
        {'Sid': 'ReadWriteRepositoryObjects', 'Effect': 'Allow',
         'Action': ['s3:GetObject', 's3:PutObject', 's3:DeleteObject',
                    's3:AbortMultipartUpload', 's3:ListMultipartUploadParts'],
         'Resource': f'{bucket}/{prefix}/*'},
    ]}


def write_private(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.pgdr-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            output.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def parse_settings(directory):
    settings_path = directory / 'settings.json'
    saved = json.loads(settings_path.read_text()) if settings_path.exists() else {}
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('bucket', 'region', 'prefix', 'profile', 'role_arn'):
        parser.add_argument(f'--{name.replace("_", "-")}',
                            default=os.environ.get(f'PGDR_S3_{name.upper()}', saved.get(name)))
    args = parser.parse_args()
    settings = vars(args)
    settings['prefix'] = settings['prefix'] or 'postgres-dr/orders'
    if any(settings[name] is None for name in ('bucket', 'region', 'profile')):
        parser.error('Set PGDR_S3_BUCKET, PGDR_S3_REGION and PGDR_S3_PROFILE on first setup')
    return parser, settings, saved


def fetch_credentials(settings):
    if settings['role_arn']:
        command = ['aws', 'sts', 'assume-role', '--role-arn', settings['role_arn'],
                   '--role-session-name', 'postgres-dr-backup', '--duration-seconds', '3600',
                   '--profile', settings['profile'], '--query', 'Credentials', '--output', 'json']
    else:
        command = ['aws', 'configure', 'export-credentials', '--profile', settings['profile'],
                   '--format', 'process']
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise ValueError('AWS CLI credentials unavailable; authenticate the selected profile first')
    return json.loads(result.stdout)


def save_configuration(directory, settings, credentials):
    config = build_config(settings, credentials)
    write_private(directory / 'pgbackrest.conf', config)
    write_private(directory / 'settings.json', json.dumps(settings, indent=2) + '\n')
    write_private(directory / 'writer-policy.json', json.dumps(writer_policy(settings), indent=2) + '\n')


def main():
    root = Path(__file__).resolve().parent.parent
    directory = Path(os.environ.get('PGDR_S3_DIR', str(root / '.local/s3')))
    parser, settings, saved = parse_settings(directory)
    try:
        validate_settings(settings)
        if saved and any(saved[name] != settings[name] for name in ('bucket', 'region', 'prefix')):
            raise ValueError('Existing repository identity differs; use a separate PGDR_S3_DIR and Compose project')
        credentials = fetch_credentials(settings)
        save_configuration(directory, settings, credentials)
    except (ValueError, KeyError, OSError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f'S3 setup failed: {error}\n')
    print(f'S3 credentials prepared privately; bucket {settings["bucket"]}, prefix {settings["prefix"]}.')
    print(f'Prefix-scoped writer policy: {directory / "writer-policy.json"}')


if __name__ == '__main__':
    main()

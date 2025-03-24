import json
import os
import sys
import argparse
import logging
import pandas as pd

from env_helper import PROTON_VERSION, SANITIZER
from version_helper import VersionHelper

RETRY = 5

if PROTON_VERSION is None:
    logging.error("PROTON_VERSION is None, could not find proton image")
    sys.exit(1)


## Load and format data
def load_json(source_dir):
    if not os.path.exists(source_dir):
        os.makedirs(source_dir)

    merged_list=[]
    for filename in os.listdir(source_dir):
        source_file = os.path.join(source_dir, filename)
        if not os.path.isfile(source_file):
            continue
        if not filename.endswith('.json'):
            continue

        with open(source_file, 'r', encoding='utf-8') as f:
            content = json.load(f)
            if isinstance(content, list):
                merged_list.extend(content)
            else:
                merged_list.append(content)
    return merged_list

def transform_data(data):
    new_data = []
    for item in data:
        metadata_list = [item.get("suite_name"), item.get("case_name"), item.get("cluster")]
        metadata = "_".join(metadata_list)

        row = item.get("row") if item.get("row") else item.get("results", {}).get("count()", 0)
        elapsed_ms = item.get("elapsed_ms") if item.get("elapsed_ms") else item.get("statistics", {}).get("elapsed_ms", 0)
        eps = float(row) / float(elapsed_ms) if elapsed_ms and float(elapsed_ms) != 0 else 0
        eps_format = f"{eps:.3f}"

        new_item = {
            "metadata": metadata,
            "suite_name": item.get("suite_name"),
            "case_name": item.get("case_name"),
            "cluster": item.get("cluster"),
            "version": item.get("version"),
            "row": row,
            "elapsed_ms": elapsed_ms,
            "eps": eps_format
        }
        new_data.append(new_item)
    return new_data

## Compare test result with benchmark
def get_compare_versions(versions: str, current_version: str):
    version_helper = VersionHelper()
    if SANITIZER == "release":
        last_release_versions = version_helper.get_previous_release_version(current_version, 1)
        specified_versions = version_helper.get_version_list(versions)
        if len(last_release_versions) == 0:
            return specified_versions, None
        last_release_version = last_release_versions[0]
        specified_versions if last_release_version in specified_versions else specified_versions.append(last_release_version)
        logging.info(f"compare versions: {specified_versions}, last release version: {last_release_version}")
        return specified_versions, last_release_version

    last_sanitizer_version = version_helper.get_previous_sanitizer_version(current_version, "nightly_test.yml", 1)
    logging.info(f"compare versions: {last_sanitizer_version}, last sanitizer version: {last_sanitizer_version}")
    if len(last_sanitizer_version) == 0:
        return None, None
    return last_sanitizer_version, last_sanitizer_version[0]
   
def calculate_percentage_change(old_value: str, new_value: str) -> float:
    old = float(old_value)
    new = float(new_value)
    diff = new - old
    percentage = (diff / old * 100) if old > 0 else float('inf')
    return percentage

def compare_benchmarks(result_list, benchmark_list, warning_version, threshold):
    warning = 0
    threshold = threshold.replace('%', '').strip()
    for result in result_list:
        for ben in benchmark_list:
            if result.get("metadata") == ben.get("metadata"):           
                bench_key = "benchmark_" + ben.get("version")
                compare_key = "compare_" + ben.get("version")
                compare_key = "compare_" + ben.get("version")
                
                compare = calculate_percentage_change(result.get("eps"), ben.get("eps"))
                result[bench_key] = ben.get("eps")
                result[compare_key] = f"{compare:.2f}%"

                if warning_version == ben.get("version"):
                    if abs(compare) > int(threshold):
                        result["warning"] = 1
                        warning = 1
                    else:
                        result["warning"] = 0

    for result in result_list:
        del result["metadata"]
    return result_list, warning

## Generate file
def generate_file_name(dir, data, key, suffix):
    output_file_name = "_".join([data[0].get("version")[:19], key])
    output_file = os.path.join(dir, f"{output_file_name}.{suffix}")
    return output_file

def generate_json(dir, data, key):
    output_file = generate_file_name(dir, data, key, "json")
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(data, f, separators=(',', ':'), ensure_ascii=False)

def generate_excel(dir, data, key):
    output_file = generate_file_name(dir, data, key, "xlsx")
    df = pd.DataFrame(data)
    df.to_excel(output_file, index=False)

def generate_markdown(dir, data):
    output_file = os.path.join(dir, f"table.md")

    headers = data[0].keys()

    markdown_table = []
    markdown_table.append('| ' + ' | '.join(headers) + ' |')
    markdown_table.append('|' + '|'.join(['---'] * len(headers)) + '|')

    for row in data:
        markdown_table.append('| ' + ' | '.join(str(row[header]) for header in headers) + ' |')

    with open(output_file, 'w') as file:
        file.write('\n'.join(markdown_table))
        file.write('\n')

    logging.info("Markdown table has been stored in 'table.md' file.")

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('--versions', type=str, required=False, help='Comma-separated list of versions for comparasion (e.g.1.0.0,1.1.0)')    
    parser.add_argument('--dir', type=str, required=True, default='./', help='Directory of test cases result')
    parser.add_argument('--threshold', type=str, required=False, default='10%', help='Threshold of benchmarking test')
    parser.add_argument('--save-benchmark', action='store_true', help='save test result as benchmark')
    return parser.parse_args()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    args = parse_args()

    # load result
    result_path = os.path.join(args.dir, "result")
    result = load_json(result_path)
    result_list = transform_data(result)
    if len(result_list) == 0:
        raise Exception("failed to load test results")

    if args.save_benchmark:
        logging.info("recorad and upload benchmark")
        save_path = os.path.join(args.dir, "benchmark", "new")
        if not os.path.exists(save_path):
            os.makedirs(save_path)
        generate_json(save_path, result_list, "benchmark")

    # load benchmark
    benchmark_path = os.path.join(args.dir, "benchmark")
    benchmark = load_json(benchmark_path)

    ## skip version with empty benchmark (failed workflow rather than warning one)
    current_version = PROTON_VERSION
    for _ in range(RETRY):
        try:
            print(f"current_version: {current_version}")
            compare_versions, warning_version = get_compare_versions(args.versions, current_version)
            if compare_versions is None:
                logging.info("compare version is None")
                break
            filtered_benchmark = [item for item in benchmark if item.get('version') in compare_versions]
            if len(filtered_benchmark) > 0 or warning_version is None:
                logging.info("warning version is None")
                break
            current_version = warning_version
        except Exception as e:
            print("Get version and benchmark exception:", str(e))
            raise e

    benchmark_list = transform_data(filtered_benchmark)
    if len(benchmark_list) == 0:
        raise Exception("failed to load benchmark")

    # compare result and benchmark
    output_data, warning = compare_benchmarks(result_list, benchmark_list, warning_version, args.threshold)
    logging.info("compare output:")
    logging.info("---------------")
    logging.info(output_data)
    logging.info("---------------")

    # generate comparasion result
    output_path = os.path.join(args.dir, "summary")
    if not os.path.exists(output_path):
        os.makedirs(output_path)
    generate_json(output_path, output_data, "result")
    generate_excel(output_path, output_data, "result")
    generate_markdown(output_path, output_data)

    if warning != 0:
        raise Exception("performance warning found!")
